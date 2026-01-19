--[[
	⚠️ Not intended for public use. ⚠️

	CarHandler.lua

	Server side vehicle controller.
	
	Handles car spawning, input syncing, drift + steering physics, and cleanup.
	Does NOT trust the client with any physics to prevent exploits or speed hacks.

	WHY:
	All movement logic is server authoritative for cheat prevention.
	Client only handles input and camera behavior.
]]

--------------------------------------------------
-- Service References
--------------------------------------------------

-- Always access services via game:GetService for consistency and performance.
-- WHY:
-- GetService guarantees the service exists and avoids edge cases where the
-- service isn't created yet or is nil when directly indexed.
local Players = game:GetService("Players")           -- Manage player instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Shared assets + remotes.
local Workspace = game:GetService("Workspace")       -- Main 3D world container.
local RunService = game:GetService("RunService")     -- Access frame/heartbeat events.

--------------------------------------------------
-- RemoteEvent References
--------------------------------------------------

-- This RemoteEvent tells the client to switch their camera to the car.
-- WHY:
-- Camera work must be done on the client for smooth visuals and responsiveness.
local CameraChange = ReplicatedStorage.Remotes:WaitForChild("ChangeCamera")

-- NOTE:
-- The Input RemoteEvent is handled in a separate script (InputListener.server.lua)
-- to keep networking responsibilities separated from gameplay logic.

--------------------------------------------------
-- Module Table
--------------------------------------------------

-- Standard Lua module pattern: all exported functions live in this table.
-- WHY:
-- Allows other scripts to require() this module and call its methods.
local CarHandler = {}

--------------------------------------------------
-- Debug Mode Toggle
--------------------------------------------------

-- Developers can toggle this to enable/disable debug prints.
-- WHY:
-- Debug output is useful during development but should be silenced for production.
local DEBUG = false

-- Debug utility function.
-- WHY:
-- Centralizes logging so you can control all debug output in one place.
local function DebugPrint(...)
	if DEBUG then                                   -- Only print when debug mode is enabled.
		print("[CarHandler]", ...)                  -- Prefix output so it's easy to filter in the console.
	end
end

--------------------------------------------------
-- Ground Check Function
--------------------------------------------------

-- This function determines if a car is grounded (touching terrain or parts).
-- WHY:
-- Prevents drift or steering logic while the car is airborne, making behavior
-- more realistic and avoiding weird mid-air turning.
local function IsCarGrounded(car)
	local root = car.PrimaryPart                    -- Main physics reference for the car.

	-- Sanity check: car must have a PrimaryPart set.
	if not root then
		return false                                -- No PrimaryPart means we can't reliably check ground.
	end

	-- The ray starts from the center of the car.
	local origin = root.Position                    -- Use the root position as raycast start point.

	-- Calculates ray distance slightly longer than half the car height.
	-- WHY:
	-- Ensures we still detect the ground when the car is slightly above due
	-- to suspension, bumps, or small physics offsets.
	local halfHeight = root.Size.Y / 2
	local rayDistance = halfHeight + 0.1            -- Add small buffer above half-height.

	-- Casts ray in the car's "down" direction relative to its orientation.
	-- WHY:
	-- If the car is tilted or flipped, its CFrame.UpVector changes, so using
	-- that ensures the ray always goes "down" relative to the car, not world.
	local direction = -root.CFrame.UpVector * rayDistance

	-- Raycast config: ignore the car itself and ignore water.
	-- WHY:
	-- We don't want the ray colliding with the car's own parts, and generally
	-- being in water shouldn't count as being "grounded" for driving logic.
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { car }     -- Ignore this car model entirely.
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	-- Perform the raycast into the world.
	local result = Workspace:Raycast(origin, direction, params)

	-- Returns true if the ray hits any valid surface.
	return result ~= nil
end

--------------------------------------------------
-- AngularVelocity Steering Setup (Modern Constraint)
--------------------------------------------------

-- Creates and attaches an AngularVelocity constraint to the car's PrimaryPart.
-- WHY:
-- BodyAngularVelocity is deprecated.
-- AngularVelocity constraint is the modern, officially supported replacement
-- that works with attachments and constraint-based physics.
local function AddAngularControl(car)
	local root = car.PrimaryPart                    -- Main part for applying rotation.

	-- Create an Attachment that defines where the angular constraint applies.
	-- WHY:
	-- Most constraints (including AngularVelocity) require at least one attachment.
	local attachment = Instance.new("Attachment")
	attachment.Name = "SteeringAttachment"          -- Named for easy debugging in the Explorer.
	attachment.Parent = root                        -- Attach directly to the car's root part.

	-- Create AngularVelocity constraint.
	-- WHY:
	-- This allows us to specify target angular velocity and torque around axes.
	local angular = Instance.new("AngularVelocity")
	angular.Name = "SteeringAngular"                -- Name for clarity in the hierarchy.

	-- The target angular velocity vector.
	-- WHY:
	-- We control only the Y component to rotate left/right (yaw).
	angular.AngularVelocity = Vector3.new(0, 0, 0)  -- Start with no rotation.

	-- Set maximum torque (strength) of the rotation.
	-- WHY:
	-- Higher torque means the constraint can more aggressively enforce its target speed.
	angular.MaxTorque = math.huge                   -- Infinite torque (within engine limits).

	-- Make the rotation relative to the attachment frame.
	-- WHY:
	-- Keeps angular behavior consistent relative to the car's local orientation.
	angular.RelativeTo = Enum.ActuatorRelativeTo.Attachment0

	-- Connect the constraint to the attachment.
	angular.Attachment0 = attachment

	-- Parent the constraint to the root part to keep things grouped.
	angular.Parent = root

	-- Return a small interface to drive this constraint in a clean way.
	return {
		-- Apply a rotational speed around the Y axis.
		-- WHY:
		-- Called from the physics loop to make the car visually align to movement.
		Apply = function(ySpeed)
			angular.AngularVelocity = Vector3.new(0, ySpeed, 0)
		end,

		-- Reset angular velocity back to zero.
		-- WHY:
		-- Prevents the car from continuing to spin when not moving or turning.
		Reset = function()
			angular.AngularVelocity = Vector3.new(0, 0, 0)
		end
	}
end

--------------------------------------------------
-- Global Input Cache
--------------------------------------------------

-- Stores real-time input states for every player.
-- WHY:
-- We use a single global RemoteEvent listener instead of per-car connections.
-- This pattern scales better and avoids event connection bloat.
local InputState = {}

--------------------------------------------------
-- Input Handler
--------------------------------------------------

-- Called from a global RemoteEvent listener in another script.
-- WHY:
-- Keeps network handling separate from the physics module and allows the server
-- to manage all inputs in one consistent place.
function CarHandler:HandleInput(player, input, action)
	local state = InputState[player]                -- Get this player's input state table.

	-- If no car / state exists yet for this player, ignore input.
	if not state then
		return
	end

	-- Convert "On"/"Off" into a boolean.
	-- WHY:
	-- Makes it easier to work with in the physics loop.
	local isOn = (action == "On")

	-- Update appropriate input flags based on input type.
	if input == "Left" then
		state.Left = isOn                           -- Track whether left key is held.
	elseif input == "Right" then
		state.Right = isOn                          -- Track whether right key is held.
	elseif input == "Brake" then
		state.Brake = isOn                          -- Track braking state.
	elseif input == "Drift" then
		state.Drift = isOn                          -- Track drift toggle.
	end
end

--------------------------------------------------
-- Car Selection
--------------------------------------------------

-- Returns the name of the car a player should spawn.
-- WHY:
-- Placeholder for future expansion: different cars per player, unlocks, etc.
function CarHandler:GetCarModel(player)
	return "Car1"                                   -- For now, every player gets "Car1".
end

--------------------------------------------------
-- Car Spawning Per Player
--------------------------------------------------

-- Public method to spawn a car for the given player.
function CarHandler:SpawnCar(player)
	-- Get the specific car model name for this player.
	local carName = self:GetCarModel(player)

	-- Look for the car model inside ReplicatedStorage.Cars.
	-- WHY:
	-- ReplicatedStorage is used for assets needed by both server and clients.
	local carModelFolder = ReplicatedStorage:WaitForChild("Cars") -- Ensure folder exists.
	local carModel = carModelFolder:FindFirstChild(carName)

	-- Validate the car: must exist, be a Model, and have a PrimaryPart set.
	if not (carModel and carModel:IsA("Model") and carModel.PrimaryPart) then
		warn(carName .. " is invalid or missing PrimaryPart") -- Helpful error for debugging.
		return                                               -- Abort spawning if invalid.
	end

	-- Clone the car so each player gets an independent copy.
	local carClone = carModel:Clone()

	-- Parent the car into the game world (grouped under Map.Cars for organization).
	-- WHY:
	-- Keeps world clean; all cars are inside one folder instead of loose in Workspace.
	local map = Workspace:FindFirstChild("Map")              -- Try to find a Map model.
	local carsFolder = map and map:FindFirstChild("Cars")    -- Attempt to get Cars folder.
	carClone.Parent = carsFolder or Workspace               -- Fallback to Workspace if folder missing.

	-- Determine the spawn position.
	-- WHY:
	-- Allows maps to define a specific SpawnPart, but still works without one.
	local spawnPart = map and map:FindFirstChild("SpawnPart")
	local spawnCFrame = spawnPart and spawnPart.CFrame or CFrame.new(0, 10, 0)

	-- Move the car to the spawn location using PivotTo.
	-- WHY:
	-- PivotTo handles full model movement based on its PrimaryPart.
	carClone:PivotTo(spawnCFrame)

	-- If PrimaryPart hasn't replicated yet (possible over network), wait for it.
	if not carClone.PrimaryPart then
		carClone:GetPropertyChangedSignal("PrimaryPart"):Wait() -- Block until PrimaryPart is set.
	end

	-- Explicitly set server as the network owner of the car's physics.
	-- WHY:
	-- Prevents clients from taking control of physics (anti-exploit).
	-- All movement is computed by the server only.
	carClone.PrimaryPart:SetNetworkOwner(nil)

	-- Tell the client to switch their camera to follow this new car.
	-- WHY:
	-- Client controls the camera for smooth visuals, server just tells them what to follow.
	CameraChange:FireClient(player, carClone, "Hitbox")

	--------------------------------------------------
	-- ⌨️ Input State Flags
	--------------------------------------------------

	-- Initialize an input state table for this player.
	-- WHY:
	-- Stores the current pressed/released state of controls that drive physics.
	InputState[player] = {
		Left = false,                              -- A/D or left arrow input.
		Right = false,                             -- D/A or right arrow input.
		Brake = false,                             -- S or down arrow braking input.
		Drift = false,                             -- Shift or special drift input.
	}

	--------------------------------------------------
	-- Steering Angular Velocity Setup
	--------------------------------------------------

	-- Setup steer controller powered by AngularVelocity.
	-- WHY:
	-- This handles visually rotating the car to match its movement direction.
	local SteeringAngular = AddAngularControl(carClone)

	--------------------------------------------------
	-- Tuning Constants (Gameplay Feel)
	--------------------------------------------------

	-- These values affect handling responsiveness, grip, braking, etc.
	local PeakSteerSpeed = 80                      -- Speed at which steering is most effective.
	local MaxSteerAngle = math.rad(3)              -- Maximum steering angle in radians at ideal speed.
	local MinSteerAngle = math.rad(1.2)            -- Minimum steering angle when steering effectiveness is low.
	local NormalTraction = 1                       -- Full grip when not drifting.
	local DriftTraction = 0.1                      -- Reduced grip during drift to allow slides.
	local DriftMultiplier = 1.8                    -- Increases steer angle during drifts.
	local BrakeStrength = 0.98                     -- Multiplier for velocity while braking (0–1).
	local SteeringResponse = 1                     -- How quickly steering responds to input changes.

	-- Steering value (smoothed over time between -1 and 1).
	local Steering = 0

	--------------------------------------------------
	-- Main Physics Loop
	--------------------------------------------------

	-- Run the car physics in a separate thread.
	task.spawn(function()
		-- Stores the previous horizontal movement direction.
		local prevFlatDir = nil

		-- Stores the last timestamp for deltaTime calculation.
		-- WHY:
		-- Using os.clock() is precise and recommended over tick().
		local lastTime = os.clock()

		-- Stores velocity from the previous frame for crash detection.
		local lastVelocity = Vector3.new(0, 0, 0)

		-- Stores the last position of the car for distance tracking.
		local prevPos = carClone.PrimaryPart.Position

		-- Accumulates total distance traveled by this car.
		local distance = 0

		-- Run the loop as long as the car exists in the world.
		while carClone.Parent do
			-- Wait for the next physics step using Heartbeat.
			-- WHY:
			-- Heartbeat is synced to the engine's physics and is stable for physics updates.
			RunService.Heartbeat:Wait()

			-- Get the current timestamp and compute deltaTime.
			local now = os.clock()
			local dt = now - lastTime
			lastTime = now

			-- Reference the car’s PrimaryPart for physics manipulation.
			local root = carClone.PrimaryPart

			-- Skip this frame if the car is not fully initialized.
			if not root then
				continue                                -- Prevents errors if the car gets destroyed mid-loop.
			end

			-- Fetch this player's input state table.
			local state = InputState[player]
			if not state then
				break                                   -- If the player left or was cleaned up, stop this loop.
			end

			-- Get the car’s current velocity.
			local vel = root.AssemblyLinearVelocity

			-- Calculate speed (magnitude of velocity vector).
			local speed = vel.Magnitude

			-- Prevent steering and rotation when the car is nearly stopped.
			-- WHY:
			-- Turning when almost stationary can cause jitter and unrealistic behavior.
			if speed < 0.5 then
				SteeringAngular.Reset()                -- Stop all angular motion.
				prevFlatDir = nil                      -- Reset direction memory.
				continue
			end

			-- Check if the car is touching the ground.
			local grounded = IsCarGrounded(carClone)

			-- Track how far the car has moved since the last frame.
			local currentPos = root.Position
			distance += (currentPos - prevPos).Magnitude
			prevPos = currentPos

			-- Optionally print distance for debugging.
			DebugPrint("Distance traveled:", math.floor(distance))

			------------------------------------------------------------
			-- BRAKING SYSTEM
			------------------------------------------------------------

			-- If the player is holding the brake input.
			if state.Brake then
				-- Apply multiplicative braking to velocity.
				vel *= BrakeStrength                   -- Gradually reduce velocity.
				speed = vel.Magnitude                  -- Recompute speed after braking.
			end

			------------------------------------------------------------
			-- STEERING INPUT PROCESSING
			------------------------------------------------------------

			-- Convert raw input booleans into a single steering direction.
			local targetSteer = 0

			if state.Left then
				targetSteer += 1                       -- Positive steer value for left.
			end

			if state.Right then
				targetSteer -= 1                       -- Negative steer value for right.
			end

			-- Calculate how effective steering should be at the current speed.
			-- WHY:
			-- At very low/high speeds, steering should feel weaker to avoid snappy turns.
			local steerEffect = 1 - math.abs(speed - PeakSteerSpeed) / PeakSteerSpeed
			steerEffect = math.clamp(steerEffect, 0, 1) -- Clamped between 0 and 1.

			-- Blend between minimum and maximum steering angles based on effectiveness.
			local maxSteerAngle =
				MinSteerAngle + (MaxSteerAngle - MinSteerAngle) * steerEffect

			-- Increase steering angle when drifting.
			if state.Drift then
				maxSteerAngle *= DriftMultiplier       -- Allow sharper turning during drift.
			end

			-- Smooth steering toward the target value.
			local steerDelta = targetSteer - Steering  -- Difference between desired and current steer.
			local steerSign = math.sign(steerDelta)    -- Direction to move Steering in.
			local steerMagnitude = math.abs(steerDelta) ^ 1.5 -- Non-linear response for snappier steering.

			-- Apply time scaled steering interpolation.
			Steering += steerSign * steerMagnitude * SteeringResponse * dt
			Steering = math.clamp(Steering, -1, 1)     -- Clamp steering range.

			------------------------------------------------------------
			-- APPLY STEERING TO VELOCITY (REALISTIC TURNING)
			------------------------------------------------------------

			-- Only steer if the car is grounded and the player is turning.
			if grounded and math.abs(Steering) > 0.001 then
				-- Choose traction based on drift state.
				local traction = state.Drift and DriftTraction or NormalTraction

				-- Calculate the steering rotation angle this frame.
				local angle = maxSteerAngle * Steering

				-- Store the car’s orientation CFrame.
				local carCFrame = root.CFrame

				-- Convert world velocity into the car’s local space.
				local localVelocity = carCFrame:VectorToObjectSpace(vel)

				-- Rotate the local velocity around the Y axis by the steering angle.
				local rotatedLocalVelocity =
					CFrame.Angles(0, angle, 0):VectorToWorldSpace(localVelocity)

				-- Convert the rotated velocity back to world space.
				local desiredVelocity =
					carCFrame:VectorToWorldSpace(rotatedLocalVelocity)

				-- Blend between current and desired velocity directions.
				local blendedDir =
					vel.Unit:Lerp(desiredVelocity.Unit, traction)

				-- Normalize to avoid invalid NaN vectors.
				if blendedDir.Magnitude > 0.01 then
					blendedDir = blendedDir.Unit
				else
					blendedDir = desiredVelocity.Unit
				end

				-- Apply the new direction while preserving speed magnitude.
				vel = blendedDir * speed
				root.AssemblyLinearVelocity = vel       -- Commit updated velocity to the physics engine.
			end

			------------------------------------------------------------
			-- ROTATE CAR TO MATCH MOVEMENT DIRECTION
			------------------------------------------------------------

			-- Remove vertical movement from velocity.
			local flatVel = Vector3.new(vel.X, 0, vel.Z)

			if flatVel.Magnitude > 1 then
				-- Current normalized horizontal direction.
				local currDir = flatVel.Unit

				if prevFlatDir then
					-- Dot and cross provide signed angle between directions.
					local dot = currDir:Dot(prevFlatDir)
					local cross = prevFlatDir:Cross(currDir)

					-- atan2 gives stable signed angle from dot and cross.
					local angleDelta = math.atan2(cross.Y, dot)

					-- Convert angle delta into angular speed (radians per second).
					local angularSpeed = angleDelta / dt

					-- Use AngularVelocity constraint to rotate car visually.
					SteeringAngular.Apply(angularSpeed)
				end

				-- Store this direction for next frame.
				prevFlatDir = currDir
			else
				-- If too slow, stop rotating and clear previous direction.
				SteeringAngular.Reset()
				prevFlatDir = nil
			end

			------------------------------------------------------------
			-- AUTO-FLIP SYSTEM
			------------------------------------------------------------

			if grounded then
				-- Compare car's UpVector with world up vector (0,1,0).
				local upDot = root.CFrame.UpVector:Dot(Vector3.new(0, 1, 0))

				-- If the up dot is too small, car is likely flipped or nearly so.
				if upDot < 0.2 then
					DebugPrint("Car flipped. Auto-flipping.")

					-- Store current position so we don't teleport horizontally.
					local pos = root.Position

					-- Extract yaw from car's CFrame using ToOrientation.
					-- WHY:
					-- Using CFrame:ToOrientation() is more robust than root.Orientation.Y.
					local _, yaw = root.CFrame:ToOrientation()

					-- Construct a new upright CFrame keeping yaw the same.
					local newCF =
						CFrame.new(pos) *
						CFrame.Angles(0, yaw, 0)

					-- Lift the car slightly to prevent clipping into ground.
					carClone:PivotTo(newCF + Vector3.new(0, 3, 0))
				end
			end

			------------------------------------------------------------
			-- CRASH DETECTION
			------------------------------------------------------------

			-- Measure sudden changes in velocity magnitude.
			local velocityChange = (lastVelocity - vel).Magnitude

			-- If above a threshold, treat it as a crash.
			if velocityChange > 50 then
				DebugPrint("Crash detected for", player.Name)
			end

			-- Store velocity for next frame's comparison.
			lastVelocity = vel
		end
	end)

	--------------------------------------------------
	-- Cleanup Logic
	--------------------------------------------------

	-- Helper to clear all input state when car or player is destroyed.
	local function DisconnectAll()
		InputState[player] = nil                      -- Remove this player's input cache.
	end

	-- If the car gets destroyed manually or otherwise, clean up input.
	carClone.Destroying:Connect(DisconnectAll)

	-- If the player leaves, destroy their car and clean up.
	player.Destroying:Connect(function()
		carClone:Destroy()                           -- Removes the car model from the world.
		DisconnectAll()                              -- Clears stored input state.
	end)
end

--------------------------------------------------
-- Start Round (Spawns Cars for All Players)
--------------------------------------------------

-- Spawns cars for everyone at the start of a race or round.
function CarHandler:StartRound()
	-- Try to find map's Cars folder for cleanup.
	local map = Workspace:FindFirstChild("Map")
	local carsFolder = map and map:FindFirstChild("Cars")

	-- Clear old car models from previous rounds.
	if carsFolder then
		carsFolder:ClearAllChildren()
	end

	-- Spawn a car for each connected player.
	for _, player in ipairs(Players:GetPlayers()) do
		self:SpawnCar(player)
	end
end

--------------------------------------------------
-- Return Module
--------------------------------------------------

-- Returns the CarHandler table so other scripts can require and use it.
return CarHandler
