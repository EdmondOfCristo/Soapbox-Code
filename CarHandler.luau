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
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--------------------------------------------------
-- RemoteEvent References
--------------------------------------------------

-- This RemoteEvent tells the client to switch their camera to the car.
-- WHY: Clients must control their camera locally for smooth following.
local CameraChange = ReplicatedStorage.Remotes:WaitForChild("ChangeCamera")

-- This RemoteEvent listens for driving input from the client (WASD, etc).
-- WHY: Input is gathered client side and interpreted server side for physics.
local InputRemote = ReplicatedStorage.Remotes:WaitForChild("Input")

--------------------------------------------------
--  Module Table
--------------------------------------------------

-- Standard Lua module pattern: all exported functions live in this table.
local CarHandler = {}

--------------------------------------------------
-- Debug Mode Toggle
--------------------------------------------------

-- Developers can toggle this to print useful information.
-- WHY: Useful for diagnosing behavior during development.
local DEBUG = false

-- This utility function only prints messages if DEBUG is true.
-- WHY: Prevents spam in production, keeps dev logs clean.
local function DebugPrint(...)
	if DEBUG then
		print("[CarHandler]", ...)
	end
end

--------------------------------------------------
-- Ground Check Function
--------------------------------------------------

-- This function determines if a car is grounded (touching terrain or parts).
-- WHY: Prevents drift or steering logic while the car is airborne.
local function IsCarGrounded(car)
	local root = car.PrimaryPart

	-- Sanity check: car must have a PrimaryPart set.
	if not root then
		return false
	end

	-- The ray starts from the center of the car.
	local origin = root.Position

	-- Calculates ray distance slightly longer than half the car height.
	-- WHY: Ensures accurate contact even when barely off the ground.
	local halfHeight = root.Size.Y / 2
	local rayDistance = halfHeight + 0.1

	-- Casts ray in the car's "down" direction relative to its orientation.
	local direction = -root.CFrame.UpVector * rayDistance

	-- Raycast config: ignore the car itself and ignore water.
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { car }
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	-- Perform the raycast into the world.
	local result = Workspace:Raycast(origin, direction, params)

	-- Returns true if the ray hits any valid surface.
	return result ~= nil
end

--------------------------------------------------
-- BodyAngularVelocity Setup
--------------------------------------------------

-- Creates and attaches a BodyAngularVelocity to the car's PrimaryPart.
-- WHY: Allows car to smoothly rotate visually based on direction changes.
local function AddAngularControl(car)
	local root = car.PrimaryPart

	local angular = Instance.new("BodyAngularVelocity")
	angular.Name = "SteeringAngular"

	-- Limits torque to only rotate around the Y axis (no barrel rolls).
	angular.MaxTorque = Vector3.new(0, math.huge, 0)

	-- Start with zero rotation.
	angular.AngularVelocity = Vector3.zero

	-- High P value = snappy but smooth responsiveness.
	angular.P = 50000

	-- Attach to the car's main body (PrimaryPart).
	angular.Parent = root

	return angular
end

--------------------------------------------------
-- Car Selection
--------------------------------------------------

-- Returns the name of the car a player should spawn.
-- WHY: Allows future support for unlockable cars, skins, or DataStore logic.
function CarHandler:GetCarModel(player)
	return "Car1" -- Static for now; replace with player data logic later.
end

--------------------------------------------------
-- Car Spawning Per Player
--------------------------------------------------

-- Public method to spawn a car for the given player.
function CarHandler:SpawnCar(player)
	-- Get the car name for the player.
	local carName = self:GetCarModel(player)

	-- Look for the car model inside ReplicatedStorage.
	local carModel = ReplicatedStorage.Cars:FindFirstChild(carName)

	-- Validate the car: must exist, be a Model, and have a PrimaryPart set.
	if not (carModel and carModel:IsA("Model") and carModel.PrimaryPart) then
		warn(carName .. " is invalid or missing PrimaryPart")
		return
	end

	-- Clone the car so each player gets an independent copy.
	local carClone = carModel:Clone()

	-- Parent the car into the game world (grouped under Map.Cars for organization).
	carClone.Parent = Workspace.Map.Cars

	-- Move the car to the spawn location.
	carClone:PivotTo(Workspace.Map.SpawnPart.CFrame)

	-- If PrimaryPart hasn't replicated yet (possible over network), wait for it.
	if not carClone.PrimaryPart then
		carClone:GetPropertyChangedSignal("PrimaryPart"):Wait()
	end

	-- Tell the client to switch their camera to follow this new car.
	CameraChange:FireClient(player, carClone, "Hitbox")

	--------------------------------------------------
	-- ⌨️ Input State Flags
	--------------------------------------------------

	-- These booleans store current input from the player.
	-- WHY: Server tracks input to apply movement safely and securely.
	local Left, Right, Brake, Drift = false, false, false, false

	-- Input connection object (to disconnect later).
	local InputConnection

	-- Connect to input RemoteEvent to listen for real time input updates.
	InputConnection = InputRemote.OnServerEvent:Connect(function(plr, input, action)
		if plr ~= player then return end

		if input == "Left" then
			Left = action == "On"
		elseif input == "Right" then
			Right = action == "On"
		elseif input == "Brake" then
			Brake = action == "On"
		elseif input == "Drift" then
			Drift = action == "On"
		end
	end)

	--------------------------------------------------
	-- Steering Angular Velocity Setup
	--------------------------------------------------

	local SteeringAngular = AddAngularControl(carClone)

	--------------------------------------------------
	-- Tuning Constants (Gameplay Feel)
	--------------------------------------------------

	-- These values affect handling responsiveness, grip, braking, etc.
	local PeakSteerSpeed = 80
	local MaxSteerAngle = math.rad(3)
	local MinSteerAngle = math.rad(1.2)
	local NormalTraction = 1
	local DriftTraction = 0.1
	local DriftMultiplier = 1.8
	local BrakeStrength = 0.98
	local SteeringResponse = 1

	-- Steering value (smoothed over time)
	local Steering = 0

	--------------------------------------------------
	-- Main Physics Loop
	--------------------------------------------------

	task.spawn(function()
		-- Stores the previous horizontal movement direction
		-- WHY: compare past and current direction to calculate turning rotation
		local prevFlatDir = nil

		-- Stores the last timestamp for deltaTime calculation
		-- WHY: deltaTime ensures physics behaves consistently across different frame rates
		local lastTime = tick()

		-- Stores velocity from the previous frame
		-- WHY: Used to detect sudden velocity changes (crash detection)
		local lastVelocity = Vector3.zero

		-- Stores the last position of the car
		-- WHY: Used to measure how far the car has traveled
		local prevPos = carClone.PrimaryPart.Position

		-- Accumulates total distance traveled
		-- WHY: Useful for debugging, stats, or race tracking
		local distance = 0

		-- Run the loop as long as the car exists in the world
		while carClone.Parent do
			-- Yield briefly so the loop runs every frame without freezing the server
			task.wait()

			-- Get the current timestamp
			local now = tick()

			-- Calculate how much time passed since the last frame
			-- WHY: Physics calculations must scale with time, not frames
			local dt = now - lastTime
			lastTime = now

			-- Reference the car’s PrimaryPart for physics manipulation
			local root = carClone.PrimaryPart

			-- Skip this frame if the car is not fully initialized
			if not root then
				continue
			end

			-- Get the car’s current velocity
			-- WHY: All steering and movement logic is based on velocity, not position
			local vel = root.AssemblyLinearVelocity

			-- Calculate speed from velocity magnitude
			-- WHY: Steering behavior changes depending on how fast the car is moving
			local speed = vel.Magnitude

			-- Prevent steering and rotation when the car is nearly stopped
			-- WHY: Turning in place looks unnatural and causes physics jitter
			if speed < 0.5 then
				SteeringAngular.AngularVelocity = Vector3.zero
				prevFlatDir = nil
				continue
			end

			-- Check if the car is touching the ground
			-- WHY: Steering in mid air would feel unrealistic and broken
			local grounded = IsCarGrounded(carClone)

			-- Track how far the car has moved since the last frame
			-- WHY: Useful for debugging, scoring, or race progress
			local currentPos = root.Position
			distance += (currentPos - prevPos).Magnitude
			prevPos = currentPos

			DebugPrint("Distance traveled:", math.floor(distance))

			------------------------------------------------------------
			-- BRAKING SYSTEM
			------------------------------------------------------------

			-- If the player is holding the brake input
			if Brake then
				-- Reduce velocity using a multiplier instead of setting it to zero
				-- WHY: Gradual deceleration feels more realistic than instant stopping
				vel *= BrakeStrength

				-- Recalculate speed after braking
				-- WHY: Speed affects steering sensitivity later in the loop
				speed = vel.Magnitude
			end

			------------------------------------------------------------
			-- STEERING INPUT PROCESSING
			------------------------------------------------------------

			-- Target steering direction based on player input
			-- WHY: convert raw inputs into a single steering value
			local targetSteer = 0

			if Left then
				targetSteer += 1
			end

			if Right then
				targetSteer -= 1
			end

			-- Calculate how effective steering should be at the current speed
			-- WHY: Cars should turn less sharply at very low or very high speeds
			local steerEffect = 1 - math.abs(speed - PeakSteerSpeed) / PeakSteerSpeed
			steerEffect = math.clamp(steerEffect, 0, 1)

			-- Blend between min and max steering angles
			-- WHY: Creates speed based steering sensitivity
			local maxSteerAngle =
				MinSteerAngle + (MaxSteerAngle - MinSteerAngle) * steerEffect

			-- Increase steering angle while drifting
			-- WHY: Drifting should allow sharper turns with less traction
			if Drift then
				maxSteerAngle *= DriftMultiplier
			end

			-- Smooth steering toward the target value
			-- WHY: Prevents instant snapping when the player taps a key
			local steerDelta = targetSteer - Steering
			local steerSign = math.sign(steerDelta)
			local steerMagnitude = math.abs(steerDelta) ^ 1.5

			-- Apply time scaled steering interpolation
			Steering += steerSign * steerMagnitude * SteeringResponse * dt
			Steering = math.clamp(Steering, -1, 1)

			------------------------------------------------------------
			-- APPLY STEERING TO VELOCITY (REALISTIC TURNING)
			------------------------------------------------------------

			-- Only steer if the car is grounded and the player is turning
			-- WHY: Prevents mid air turning and unnecessary calculations
			if grounded and math.abs(Steering) > 0.001 then
				-- Choose traction based on drift state
				-- WHY: Drifting reduces grip to allow sliding
				local traction = Drift and DriftTraction or NormalTraction

				-- Calculate the steering rotation angle
				local angle = maxSteerAngle * Steering

				-- Store the car’s orientation
				local carCFrame = root.CFrame

				-- Convert velocity into the car’s local space
				-- WHY: Steering is easier to apply in the car’s forward/right directions
				local localVelocity = carCFrame:VectorToObjectSpace(vel)

				-- Rotate the velocity by the steering angle
				-- WHY: Simulates the wheels changing direction
				local rotatedLocalVelocity =
					CFrame.Angles(0, angle, 0):VectorToWorldSpace(localVelocity)

				-- Convert the rotated velocity back to world space
				local desiredVelocity =
					carCFrame:VectorToWorldSpace(rotatedLocalVelocity)

				-- Blend between current and desired directions
				-- WHY: Traction controls how much the car “slides” vs “grips”
				local blendedDir =
					vel.Unit:Lerp(desiredVelocity.Unit, traction)

				-- Normalize to avoid invalid vectors
				if blendedDir.Magnitude > 0.01 then
					blendedDir = blendedDir.Unit
				else
					blendedDir = desiredVelocity.Unit
				end

				-- Apply the new direction while preserving speed
				-- WHY: Steering should change direction, not velocity magnitude
				vel = blendedDir * speed
				root.AssemblyLinearVelocity = vel
			end

			------------------------------------------------------------
			-- ROTATE CAR TO MATCH MOVEMENT DIRECTION
			------------------------------------------------------------

			-- Remove vertical movement from velocity
			-- WHY: only want horizontal turning rotation
			local flatVel = Vector3.new(vel.X, 0, vel.Z)

			if flatVel.Magnitude > 1 then
				local currDir = flatVel.Unit

				if prevFlatDir then
					-- Dot & cross determine signed angle between directions
					-- WHY: Allows us to calculate rotation direction and magnitude
					local dot = currDir:Dot(prevFlatDir)
					local cross = prevFlatDir:Cross(currDir)

					-- atan2 gives a stable signed angle
					local angleDelta = math.atan2(cross.Y, dot)

					-- Convert angle into angular speed
					local angularSpeed = angleDelta / dt

					-- Rotate the car visually
					SteeringAngular.AngularVelocity =
						Vector3.new(0, angularSpeed, 0)
				end

				prevFlatDir = currDir
			else
				SteeringAngular.AngularVelocity = Vector3.zero
				prevFlatDir = nil
			end

			------------------------------------------------------------
			-- AUTO-FLIP SYSTEM
			------------------------------------------------------------

			if grounded then
				-- Check if the car is upside down
				-- WHY: Prevents players from getting stuck permanently
				local upDot = root.CFrame.UpVector:Dot(Vector3.new(0, 1, 0))

				if upDot < 0.2 then
					DebugPrint("Car flipped. Auto-flipping.")

					local pos = root.Position

					-- Reset orientation while keeping yaw direction
					local newCF =
						CFrame.new(pos) *
						CFrame.Angles(0, math.rad(root.Orientation.Y), 0)

					-- Lift the car slightly to avoid ground clipping
					carClone:PivotTo(newCF + Vector3.new(0, 3, 0))
				end
			end

			------------------------------------------------------------
			-- CRASH DETECTION
			------------------------------------------------------------

			-- Measure sudden velocity change
			-- WHY: Large changes indicate collisions
			local velocityChange = (lastVelocity - vel).Magnitude

			if velocityChange > 50 then
				DebugPrint("Crash detected for", player.Name)
			end

			-- Store velocity for the next frame
			lastVelocity = vel
		end
	end)

	--------------------------------------------------
	-- Cleanup Logic
	--------------------------------------------------

	-- Helper to disconnect all input when car or player is destroyed.
	local function DisconnectAll()
		if InputConnection then
			InputConnection:Disconnect()
			InputConnection = nil
		end
	end

	-- If the car gets destroyed manually or otherwise, clean up.
	carClone.Destroying:Connect(DisconnectAll)

	-- If the player leaves, destroy the car and clean up.
	player.Destroying:Connect(function()
		carClone:Destroy()
		DisconnectAll()
	end)
end

--------------------------------------------------
-- Start Round (Spawns Cars for All Players)
--------------------------------------------------

-- Spawns cars for everyone at the start of a race or round.
function CarHandler:StartRound()
	-- Clear old car models from previous rounds.
	Workspace.Map.Cars:ClearAllChildren()

	-- Spawn a car for each connected player.
	for _, player in ipairs(Players:GetPlayers()) do
		self:SpawnCar(player)
	end
end

--------------------------------------------------
-- Return Module
--------------------------------------------------

-- Returns the CarHandler table so other scripts can use it.
return CarHandler
