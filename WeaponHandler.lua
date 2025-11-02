local userInputService = game:GetService("UserInputService")
local runService = game:GetService("RunService")
local debrisService = game:GetService("Debris")

local replicatedStorage = game.ReplicatedStorage
local springModule = require(replicatedStorage.Modules.Libraries.Spring)
local helperFunctions = require(replicatedStorage.Modules.Extra.HelperFunctions)

local isServer = runService:IsServer()

local WeaponClient = {}
local WeaponServer = {}
WeaponClient.__index = WeaponClient
WeaponServer.__index = WeaponServer

---------------------------
-- CLIENT SIDE WEAPON LOGIC
---------------------------
function WeaponClient.init(viewmodel, weaponFolder:Folder, weaponModel:Model)
	print("Initializing Weapon")
	local self = setmetatable({}, WeaponClient)
	self.guiHandler = require(replicatedStorage.Modules.Handlers.GuiHandler)

	self.values = weaponFolder.Values
	self.sounds = weaponModel.Sounds
	self.animations = weaponFolder.Animations
	self.events = replicatedStorage.Weapons.Events
	self.viewmodel = viewmodel

	self.ammo = self.values.MaxAmmo.Value
	self.camera = workspace.CurrentCamera

	self.isFiring = false

	self.sounds.EquipSound:Play()
	self.viewmodel:playAnimation(self.animations.Equip)
	self.viewmodel:playAnimation(self.animations.Idle)
	self.viewmodel:preloadAnimation(self.animations.Reload)
	self.viewmodel:preloadAnimation(self.animations.ADS)
	self.viewmodel:preloadAnimation(self.animations.ADSShoot)

	self.events.AmmoChanged:Fire(self.ammo, self.values.MaxAmmo.Value)
	self.guiHandler.setAmmoLabelVisibility(true)

	self.inputBeginConnection = userInputService.InputBegan:Connect(function(input, gpe)
		if not gpe then
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
				if weaponFolder:GetAttribute("automatic") then
					helperFunctions.safeDisconnect(self.firingConnection)
					self.isFiring = true
					self.firingConnection = runService.Heartbeat:Connect(function(dt) self:fireWeapon() end)
				elseif weaponFolder:GetAttribute("manual") then
					self:fireWeapon()
				end

				if self.ammo <= 0 and not self.isReloading then
					self.sounds.EmptyClip:Play()
					helperFunctions.safeDisconnect(self.firingConnection)
					return
				end
			end

			if input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
				self.isADS = true
				self.viewmodel:playAnimation(self.animations.ADS)
			end

			if input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.ButtonX then
				self:reloadWeapon()
			end
		end

		if gpe then
			helperFunctions.safeDisconnect(self.firingConnection)
		end
	end)

	self.inputEndConnection = userInputService.InputEnded:Connect(function(input, gpe)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			if weaponFolder:GetAttribute("automatic") then
				self.isFiring = false
				helperFunctions.safeDisconnect(self.firingConnection)
			end
		end

		if not gpe then
			if input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
				self.isADS = false
				self.viewmodel:stopAnimation(self.animations.ADS)
			end
		end
	end)

	return self
end

function WeaponClient:uninit()
	self.inputBeginConnection:Disconnect()
	self.inputEndConnection:Disconnect()
	self.viewmodel:stopAnimation(self.animations.Idle)
	self.sounds.EquipSound:Play()
	self.guiHandler.setAmmoLabelVisibility(false)
end

function WeaponClient:reloadWeapon()
	if self.ammo == self.values.MaxAmmo.Value then return end
	if self.isFiring then return end
	if self.isReloading then return end
	self.isReloading = true

	self.events.Reload:FireServer()

	self.sounds.ReloadSound.PlaybackSpeed = self.sounds.ReloadSound.TimeLength/self.values.ReloadTime.Value

	self.viewmodel:playAnimation(self.animations.Reload)

	local tracks = self.viewmodel:getAnimationTracks(self.animations.Reload)
	tracks[1]:AdjustSpeed(tracks[1].Length/self.values.ReloadTime.Value)
	tracks[2]:AdjustSpeed(tracks[2].Length/self.values.ReloadTime.Value)

	self.guiHandler.reloading(self.values.ReloadTime.Value)

	self.sounds.ReloadSound:Play()

	task.wait(self.values.ReloadTime.Value)

	self.ammo = self.values.MaxAmmo.Value
	self.events.AmmoChanged:Fire(self.ammo, self.values.MaxAmmo.Value)

	self.isReloading = false
end

function WeaponClient:fireWeapon()
	if self.isReloading then return end
	if self.ammo <= 0 then return end
	if self.fireDebounce then return end
	self.ammo -= 1

	self.events.AmmoChanged:Fire(self.ammo, self.values.MaxAmmo.Value)

	local camera = workspace.CurrentCamera

	self.events.Fire:FireServer(camera.CFrame, self.isADS)

	if not self.isADS then
		self.viewmodel:playAnimation(self.animations.Shoot)		
	else
		self.viewmodel:playAnimation(self.animations.ADSShoot)	
	end

	self.guiHandler.updateAmmoLabel(self.ammo, self.values.MaxAmmo.Value)

	self.viewmodel:getWeaponModel().GunPoint.MuzzleFlash1:Emit();
	self.viewmodel:getWeaponModel().GunPoint.MuzzleFlash2:Emit();

	self.fireDebounce = true
	task.wait(self.values.ShotDelay.Value)
	self.fireDebounce = false
end

---------------------------
-- SERVER SIDE WEAPON LOGIC
---------------------------

-- detect humanoid hit
local function hitHumanoid(instance: Instance)
	local character = instance.Parent
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		return humanoid, instance
	end
end

-- create bullethole visual
local function createBulletHole(raycastResult: RaycastResult)
	local bulletHoleTypes = replicatedStorage.Weapons.BulletHoles
	local material = raycastResult.Instance.Material
	local folder = bulletHoleTypes:FindFirstChild(material.Name)
	if not folder then return end

	local variants = folder:GetChildren()
	if #variants == 0 then return end

	local hole = variants[math.random(#variants)]:Clone()
	hole.Parent = workspace
	hole.CFrame = CFrame.lookAt(raycastResult.Position, raycastResult.Position + raycastResult.Normal)
	debrisService:AddItem(hole, 100)
end

function WeaponServer.init(weaponFolder, player)
	local self = setmetatable({}, WeaponServer)
	self.values = weaponFolder.Values
	self.remotes = replicatedStorage.Weapons.Events
	self.ammo = self.values.MaxAmmo.Value
	self.player = player

	self.lastGunshot = 0

	self.weaponClone = weaponFolder.Weapon:Clone()
	self.weaponClone.Parent = player.Character

	local motor6d = Instance.new("Motor6D")
	motor6d.Parent = player.Character["Right Arm"]
	motor6d.Part0 = player.Character["Right Arm"]
	motor6d.Part1 = self.weaponClone.Handle
	self.sounds = self.weaponClone.Sounds

	return self
end

function WeaponServer:uninit()
	helperFunctions.safeDisconnect(self.fireConnection)
	helperFunctions.safeDisconnect(self.reloadConnection)	
	self.weaponClone:Destroy()
end

function WeaponServer:reloadWeapon()
	if self.ammo == self.values.MaxAmmo.Value then return end
	if self.isReloading then return end

	self.isReloading = true
	task.wait(self.values.ReloadTime.Value)
	self.isReloading = false

	self.ammo = self.values.MaxAmmo.Value
end

function WeaponServer:damageDetection(rayResult: RaycastResult)
	local humanoid, bodyPart = hitHumanoid(rayResult.Instance)
	if not humanoid then return false end

	if bodyPart.Name == "Head" then
		humanoid:TakeDamage(self.values.HeadshotDamagePerBullet.Value)
	else
		humanoid:TakeDamage(self.values.DamagePerBullet.Value)
	end

	return true
end

function WeaponServer:fireRay(startCF: CFrame, isADS: boolean, rayparams: RaycastParams, onHit)
	if not rayparams then
		rayparams = RaycastParams.new()
		rayparams.FilterType = Enum.RaycastFilterType.Exclude
		rayparams.FilterDescendantsInstances = { self.player.Character }
	end

	local direction = startCF.LookVector * self.values.BulletRange.Value
	local firstRay = workspace:Raycast(startCF.Position, direction, rayparams)

	if firstRay then
		-- Calculate bullet spread
		local baseDir = (firstRay.Position - startCF.Position).Unit
		local maxSpread = isADS and self.values.ADSSpread.Value or self.values.HipSpread.Value

		local spreadPitch = math.rad(math.random(-maxSpread * .5, maxSpread * .5))
		local spreadYaw = math.rad(math.random(-maxSpread * .5, maxSpread * .5))
		local spreadCF = CFrame.Angles(spreadPitch, spreadYaw, 0)

		local finalDirection = (CFrame.new(Vector3.new(), baseDir) * spreadCF).LookVector * self.values.BulletRange.Value
		local finalRay = workspace:Raycast(startCF.Position, finalDirection, rayparams)

		if finalRay then
			onHit(finalRay)
		end
	end
end

function WeaponServer:fireWeapon(cameraCF:CFrame, isADS:boolean)
	local currentTime = tick()

	if currentTime - self.lastGunshot < self.values.ShotDelay.Value then return end
	if self.ammo <= 0 then return end
	if self.isReloading then return end

	self.ammo -= 1
	self.weaponClone.Sounds.FireSound:Play()

	self:fireRay(cameraCF, isADS, nil, function(rayResult)
		if not self:damageDetection(rayResult) then
			createBulletHole(rayResult)
		end
	end)

	self.lastGunshot = currentTime
end

if isServer then
	return WeaponServer
else
	return WeaponClient
end
