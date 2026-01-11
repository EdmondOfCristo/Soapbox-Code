--[[
	⚠️ Not intended for public use. ⚠️

	CarHandler.lua

	Server-side car controller.

	Responsible for:
	- Spawning cars
	- Receiving player input
	- Applying steering / drift physics
	- Handling cleanup when player or car is destroyed

	All server-side logic to prevent client-side cheating or movement overrides.
]]

-- RemoteEvent used to change the player's camera to the car
local CameraChange = game.ReplicatedStorage.Remotes.ChangeCamera

-- RemoteEvent used to receive driving inputs from the client
local InputRemote = game.ReplicatedStorage.Remotes.Input

local CarHandler = {}

-- Enables debug prints when true
local DEBUG = false

-- Wrapper function to avoid spamming output unless debugging
local function DebugPrint(...)
	if DEBUG then
		print("[CarHandler]", ...)
	end
end

--[[ 
	Checks if the car is touching the ground.
	Uses a raycast straight "down" relative to the car.
	This allows proper behavior when the car is tilted.
	WHY:
	This prevents steering or physics calculations while in the air or flipping.
]]
local function IsCarGrounded(car)
	local root = car.PrimaryPart
	if not root then
		return false
	end

	local origin = root.Position -- Start ray at the car's center

	local halfHeight = root.Size.Y / 2 -- Half height ensures ray reaches below the car body

	local localDown = -root.CFrame.UpVector -- Down direction relative to the car's orientation (accounts for tilt)

	local rayDistance = halfHeight + 0.1 -- Slight buffer to guarantee ground detection
	local direction = localDown * rayDistance

	-- Raycast settings
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { car } -- ignore the car itself
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	local result = workspace:Raycast(origin, direction, params)

	-- If the ray hit anything, the car is grounded
	return result ~= nil
end

--[[ 
	Adds a BodyAngularVelocity to the car.
	This is used to rotate the car visually based on velocity direction.
	WHY:
	Simulates car steering visually. Only applies torque on Y axis (yaw).
]]
local function AddAngularControl(car)
	local root = car.PrimaryPart

	local angular = Instance.new("BodyAngularVelocity")
	angular.Name = "SteeringAngular"

	-- Only allow Y-axis rotation (yaw)
	angular.MaxTorque = Vector3.new(0, math.huge, 0)

	angular.AngularVelocity = Vector3.zero
	angular.P = 50000 -- responsiveness of angular force
	angular.Parent = root

	return angular
end

-- Placeholder function for future data-based car selection
function CarHandler:GetCarModel(player)
	return "Car1" -- would normally come from player data / datastore
end

--[[ 
	Spawns a car for a specific player.
	Sets up input handling, physics loop, and cleanup.
]]
function CarHandler:SpawnCar(Plr, SpawnPoint)
	local Car = CarHandler:GetCarModel(Plr)
	local CarModel = game.ReplicatedStorage.Cars:FindFirstChild(Car)

	-- Validate the car model
	if not (CarModel and CarModel:IsA("Model") and CarModel.PrimaryPart) then
		warn(Car .. " is invalid or missing PrimaryPart")
		return
	end

	-- Clone and place the car
	local CarClone = CarModel:Clone()
	CarClone.Parent = workspace.Map.Cars
	CarClone:PivotTo(workspace.Map.SpawnPart.CFrame)

	-- Safety: wait for PrimaryPart replication if needed
	if not CarClone.PrimaryPart then
		CarClone:GetPropertyChangedSignal("PrimaryPart"):Wait()
	end

	DebugPrint("Car spawned for", Plr.Name)

	-- Switch the player's camera to follow the car
	CameraChange:FireClient(Plr, CarClone, "Hitbox")

	-- Input state flags
	local Left, Right, Brake, Drift = false, false, false, false
	local InputConnection

	-- Receive input from client and update state flags
	InputConnection = InputRemote.OnServerEvent:Connect(function(player, input, action)
		if player ~= Plr then
			return
		end

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

	-- Steering angular controller
	local SteeringAngular = AddAngularControl(CarClone)

	-- =============================
	-- TUNING VALUES
	-- =============================
	local LoopSpeed = nil -- nil = run every frame
	local TurnAmount = 0.015
	local MaxSpeed = 120
	local PeakSteerSpeed = 80
	local MaxSteerAngle = math.rad(3)
	local MinSteerAngle = math.rad(1.2)
	local MaxSteerRate = 10
	local MinSteerRate = 6
	local NormalTraction = 1
	local DriftTraction = 0.1
	local DriftMultiplier = 1.8
	local BrakeStrength = 0.98
	local SteeringResponse = 1
	local Steering = 0 -- current steering interpolation value

	-- Main physics loop
	task.spawn(function()
		local prevFlatDir = nil -- last horizontal movement direction
		local lastTime = tick()
		local lastVelocity = Vector3.zero
		local prevPos = CarClone.PrimaryPart.Position
		local distance = 0

		while CarClone.Parent do
			task.wait(LoopSpeed)

			local now = tick()
			local dt = now - lastTime
			lastTime = now

			local root = CarClone.PrimaryPart
			if not root then
				continue
			end

			local vel = root.AssemblyLinearVelocity
			local speed = vel.Magnitude

			-- Disable steering when almost stopped
			if speed < 0.5 then
				SteeringAngular.AngularVelocity = Vector3.zero
				prevFlatDir = nil
				continue
			end

			local grounded = IsCarGrounded(CarClone)

			-- Track distance traveled
			local currentPos = root.Position
			distance += (currentPos - prevPos).Magnitude
			prevPos = currentPos

			DebugPrint("Distance traveled by", Plr.Name, ":", math.floor(distance))

			-- Brake reduces velocity multiplicatively
			if Brake then
				vel *= BrakeStrength
				speed = vel.Magnitude
			end

			-- Determine desired steering direction
			local targetSteer = 0

			if Left then
				targetSteer += 1
			end

			if Right then
				targetSteer -= 1
			end

			-- Steering effectiveness curve based on speed
			local steerEffect = 1 - math.abs(speed - PeakSteerSpeed) / PeakSteerSpeed
			steerEffect = math.clamp(steerEffect, 0, 1)

			local maxSteerAngle =
				MinSteerAngle + (MaxSteerAngle - MinSteerAngle) * steerEffect

			local steerRate =
				MinSteerRate + (MaxSteerRate - MinSteerRate) * steerEffect

			-- Drifting increases steering angle
			if Drift then
				maxSteerAngle *= DriftMultiplier
			end

			-- Smoothly interpolate steering input
			local steerDelta = targetSteer - Steering

			local steerSign = math.sign(steerDelta)
			local steerMagnitude = math.abs(steerDelta) ^ 1.5

			Steering += steerSign * steerMagnitude * SteeringResponse * dt
			Steering = math.clamp(Steering, -1, 1)

			-- =============================
			-- CFRAME / VELOCITY STEERING MATH
			-- =============================
			if grounded and math.abs(Steering) > 0.001 then
				local traction = Drift and DriftTraction or NormalTraction
				local angle = maxSteerAngle * Steering

				local carCFrame = root.CFrame

				-- Convert velocity into car-local space
				local localVelocity =
					carCFrame:VectorToObjectSpace(vel)

				-- Rotate local velocity by steering angle
				local rotatedLocalVelocity =
					CFrame.Angles(0, angle, 0):VectorToWorldSpace(localVelocity)

				-- Convert rotated velocity back into world space
				local desiredVelocity =
					carCFrame:VectorToWorldSpace(rotatedLocalVelocity)

				-- Blend current direction with desired direction
				local blendedDir =
					vel.Unit:Lerp(desiredVelocity.Unit, traction)

				-- Normalize to avoid invalid vectors
				if blendedDir.Magnitude > 0.01 then
					blendedDir = blendedDir.Unit
				else
					blendedDir = desiredVelocity.Unit
				end

				-- Apply new direction without changing speed
				vel = blendedDir * speed
				root.AssemblyLinearVelocity = vel
			end

			-- =============================
			-- ROTATION FROM MOVEMENT DIRECTION
			-- =============================
			local flatVel = Vector3.new(vel.X, 0, vel.Z)

			if flatVel.Magnitude > 1 then
				local currDir = flatVel.Unit

				if prevFlatDir then
					-- Dot & cross determine signed angle between directions
					local dot = currDir:Dot(prevFlatDir)
					local cross = prevFlatDir:Cross(currDir)

					-- atan2 gives rotation direction and magnitude
					local angleDelta = math.atan2(cross.Y, dot)
					local angularSpeed = angleDelta / dt

					-- Rotate car to face movement direction
					SteeringAngular.AngularVelocity =
						Vector3.new(0, angularSpeed, 0)
				end

				prevFlatDir = currDir
			else
				SteeringAngular.AngularVelocity = Vector3.zero
				prevFlatDir = nil
			end

			-- =============================
			-- AUTO-FLIP SYSTEM
			-- =============================
			if grounded then
				local upDot =
					root.CFrame.UpVector:Dot(Vector3.new(0, 1, 0))

				-- If the car is upside down
				if upDot < 0.2 then
					DebugPrint("Car flipped. Auto-flipping.")

					local pos = root.Position
					local newCF =
						CFrame.new(pos)
						* CFrame.Angles(0, math.rad(root.Orientation.Y), 0)

					-- Lift slightly to avoid ground collision
					CarClone:PivotTo(newCF + Vector3.new(0, 3, 0))
				end
			end

			-- =============================
			-- CRASH DETECTION
			-- =============================
			local velocityChange = (lastVelocity - vel).Magnitude
			if velocityChange > 50 then
				DebugPrint(
					"Crash detected for",
					Plr.Name,
					"- ΔV:",
					velocityChange
				)
			end

			lastVelocity = vel
		end
	end)

	-- =============================
	-- CLEANUP
	-- =============================
	local CarDestroyingCleanup
	local PlrLeavingCleanup

	CarDestroyingCleanup = CarClone.Destroying:Connect(function()
		if CarDestroyingCleanup then
			CarDestroyingCleanup:Disconnect()
			CarDestroyingCleanup = nil
		end

		if PlrLeavingCleanup then
			PlrLeavingCleanup:Disconnect()
			PlrLeavingCleanup = nil
		end

		if InputConnection then
			InputConnection:Disconnect()
			InputConnection = nil
		end
	end)

	PlrLeavingCleanup = Plr.Destroying:Connect(function()
		CarClone:Destroy()

		if PlrLeavingCleanup then
			PlrLeavingCleanup:Disconnect()
			PlrLeavingCleanup = nil
		end

		if CarDestroyingCleanup then
			CarDestroyingCleanup:Disconnect()
			CarDestroyingCleanup = nil
		end

		if InputConnection then
			InputConnection:Disconnect()
			InputConnection = nil
		end
	end)
end

-- Spawns cars for all players at the start of a round
function CarHandler:StartRound()
	workspace.Map.Cars:ClearAllChildren()

	for _, player in pairs(game.Players:GetPlayers()) do
		CarHandler:SpawnCar(player)
	end
end

return CarHandler
