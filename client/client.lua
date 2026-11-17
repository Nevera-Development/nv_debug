local H = Config.Highlight
local settings = { highlight = H.enabled }
local hover = { entity = nil, seen = 0, coords = nil, coordsSeen = 0 }
local debugTargets = {}
local selectedEntity
local selectionBusy = false
local raycastCoords
local targetEntity
local godmode = false
local invisible = false
local editorActive = false

local typeNames = { [1] = 'Ped', [2] = 'Vehicle', [3] = 'Object' }
local notifyStyles = {
    Success = { type = 'success', icon = 'bell' },
    Error = { type = 'error', icon = 'ban' },
    Copied = { type = 'success', icon = 'copy' },
}

local function hexToRgb(hex)
    hex = hex:gsub('#', '')
    return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

local ar, ag, ab = hexToRgb(Config.Color)

local function showNotification(title, msg)
    local style = notifyStyles[title] or notifyStyles.Success
    lib.notify({ title = title, description = msg, type = style.type, icon = style.icon })
end

local function copy(value, label)
    lib.setClipboard(tostring(value))
    showNotification('Copied', label)
end

local function orDefault(value, default)
    if not value or tostring(value):match('^%s*$') then return default end
    return value
end

local function modelName(entity)
    local name = GetEntityArchetypeName(entity)
    if name == '' then return tostring(GetEntityModel(entity)) end
    return name
end

local function control(entity)
    if not NetworkGetEntityIsNetworked(entity) or NetworkHasControlOfEntity(entity) then return true end
    local timeout = GetGameTimer() + 1000
    while not NetworkHasControlOfEntity(entity) and GetGameTimer() < timeout do
        NetworkRequestControlOfEntity(entity)
        Wait(0)
    end
    return NetworkHasControlOfEntity(entity)
end

local function parseCoords(text)
    local nums = {}
    local cleaned = (tostring(text):gsub('vec%a*%d', ''))
    for n in cleaned:gmatch('-?%d+%.?%d*') do nums[#nums + 1] = tonumber(n) end
    if #nums >= 3 then return vec3(nums[1], nums[2], nums[3]) end
end

local function teleport(coords)
    local entity = (cache.vehicle and cache.seat == -1) and cache.vehicle or cache.ped
    SetEntityCoords(entity, coords.x, coords.y, coords.z, false, false, false, false)
end

local function teleportToWaypoint()
    if not IsWaypointActive() then return showNotification('Error', 'No waypoint set.') end
    local wp = GetBlipInfoIdCoord(GetFirstBlipInfoId(8))
    local entity = (cache.vehicle and cache.seat == -1) and cache.vehicle or cache.ped
    FreezeEntityPosition(entity, true)
    local z, found = 1000.0, false
    while z > -100.0 do
        RequestCollisionAtCoord(wp.x, wp.y, z)
        SetEntityCoordsNoOffset(entity, wp.x, wp.y, z, false, false, false)
        Wait(25)
        local ok, groundZ = GetGroundZFor_3dCoord(wp.x, wp.y, z, false)
        if ok then
            SetEntityCoordsNoOffset(entity, wp.x, wp.y, groundZ + 1.0, false, false, false)
            found = true
            break
        end
        z -= 50.0
    end
    FreezeEntityPosition(entity, false)
    showNotification(found and 'Success' or 'Error', found and 'Teleported to waypoint.' or 'Ground not found.')
end

local function loadModel(name)
    local hash = joaat(name)
    if not IsModelValid(hash) then return end
    if pcall(lib.requestModel, hash, 2000) then return hash end
end

local function loadAnimDict(dict)
    return DoesAnimDictExist(dict) and pcall(lib.requestAnimDict, dict, 2000)
end

local boxEdges = { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }
local boxSigns = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }

local function drawBoxLines(points, r, g, b, a)
    for i = 1, #boxEdges do
        local p1, p2 = points[boxEdges[i][1]], points[boxEdges[i][2]]
        DrawLine(p1.x, p1.y, p1.z, p2.x, p2.y, p2.z, r, g, b, a)
    end
end

local function entityBoxPoints(entity, min, max)
    local points = {}
    for level = 0, 1 do
        local z = level == 0 and min.z or max.z
        for i = 1, 4 do
            local sx = boxSigns[i][1] == -1 and min.x or max.x
            local sy = boxSigns[i][2] == -1 and min.y or max.y
            points[#points + 1] = GetOffsetFromEntityInWorldCoords(entity, sx, sy, z)
        end
    end
    return points
end

local function zoneBoxPoints(center, width, height, rotation)
    local rad = math.rad(rotation)
    local c, s = math.cos(rad), math.sin(rad)
    local half, points = width / 2, {}
    for level = 0, 1 do
        local z = center.z + (level == 0 and -height / 2 or height / 2)
        for i = 1, 4 do
            local x, y = boxSigns[i][1] * half, boxSigns[i][2] * half
            points[#points + 1] = vec3(center.x + x * c + y * s, center.y - x * s + y * c, z)
        end
    end
    return points
end

local function drawText3D(coords, text, r, g, b, scale)
    SetDrawOrigin(coords.x, coords.y, coords.z, 0)
    SetTextScale(0.0, scale or 0.3)
    SetTextFont(0)
    SetTextProportional(true)
    SetTextColour(r, g, b, 255)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function drawRotationArc(coords, dir1, dir2, r, g, b, radius)
    local segments = 12
    local last
    for i = 0, segments do
        local angle = (i / segments) * (math.pi * 1.5)
        local point = coords + dir1 * (math.cos(angle) * radius) + dir2 * (math.sin(angle) * radius)
        if last then
            DrawLine(last.x, last.y, last.z, point.x, point.y, point.z, r, g, b, 255)
            if i == segments then
                local dir = point - last
                DrawMarker(0, point.x, point.y, point.z, dir.x, dir.y, dir.z, 0.0, 0.0, 0.0, 0.08, 0.08, 0.08, r, g, b, 255, false, true, 2, false, nil, nil, false)
            end
        end
        last = point
    end
end

local function drawAxes(entity)
    local coords = GetEntityCoords(entity)
    local rot = GetEntityRotation(entity, 2)
    local forward, right, up = GetEntityMatrix(entity)
    local xEnd, yEnd, zEnd = coords + right * 1.2, coords + forward * 1.2, coords + up * 1.2

    DrawLine(coords.x, coords.y, coords.z, xEnd.x, xEnd.y, xEnd.z, 255, 0, 0, 255)
    DrawLine(coords.x, coords.y, coords.z, yEnd.x, yEnd.y, yEnd.z, 0, 255, 0, 255)
    DrawLine(coords.x, coords.y, coords.z, zEnd.x, zEnd.y, zEnd.z, 0, 0, 255, 255)

    if H.rotationArcs then
        drawRotationArc(coords, forward, up, 255, 50, 50, 0.6)
        drawRotationArc(coords, right, up, 50, 255, 50, 0.6)
        drawRotationArc(coords, right, forward, 50, 50, 255, 0.6)
    end

    drawText3D(xEnd, 'X', 255, 100, 100)
    drawText3D(yEnd, 'Y', 100, 255, 100)
    drawText3D(zEnd, 'Z', 100, 100, 255)
    drawText3D(vec3(coords.x, coords.y, coords.z + 0.2), ('Rot: X: %.1f | Y: %.1f | Z: %.1f'):format(rot.x, rot.y, rot.z), 255, 255, 255, 0.28)
end

local function buildInfo(entity)
    local etype = GetEntityType(entity)
    local lines = {
        modelName(entity),
        ('%s  |  ID %d'):format(typeNames[etype] or 'Entity', entity),
        'Hash ' .. tostring(GetEntityModel(entity)),
    }
    if NetworkGetEntityIsNetworked(entity) then
        lines[#lines + 1] = 'Net ID ' .. NetworkGetNetworkIdFromEntity(entity)
    else
        lines[#lines + 1] = 'Local entity'
    end
    if etype == 1 or etype == 2 then
        lines[#lines + 1] = ('Health %d / %d'):format(GetEntityHealth(entity), GetEntityMaxHealth(entity))
    end
    if etype == 2 then
        lines[#lines + 1] = 'Plate ' .. GetVehicleNumberPlateText(entity)
    end
    lines[#lines + 1] = ('Distance %.1fm'):format(#(GetEntityCoords(cache.ped) - GetEntityCoords(entity)))
    return lines
end

local function drawInfoPanel(coords, lines)
    local onScreen, sx, sy = World3dToScreen2d(coords.x, coords.y, coords.z)
    if not onScreen then return end
    local lineHeight = 0.0185
    local height = #lines * lineHeight + 0.01
    local top = sy - height
    DrawRect(sx, top + height / 2, 0.14, height, 28, 30, 36, 215)
    for i = 1, #lines do
        SetTextFont(4)
        SetTextScale(0.0, 0.3)
        SetTextCentre(true)
        if i == 1 then SetTextColour(ar, ag, ab, 255) else SetTextColour(255, 255, 255, 235) end
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName(lines[i])
        EndTextCommandDisplayText(sx, top + 0.005 + (i - 1) * lineHeight)
    end
end

CreateThread(function()
    local active, min, max, lines, nextInfo, closedSince
    while true do
        local now = GetGameTimer()
        if selectedEntity and not selectionBusy and not lib.getOpenContextMenu() then
            closedSince = closedSince or now
            if now - closedSince > 300 then
                selectedEntity = nil
                closedSince = nil
            end
        else
            closedSince = nil
        end
        local entity
        if settings.highlight then
            entity = selectedEntity or (hover.entity and now - hover.seen < H.grace and hover.entity) or nil
        end
        local ray = settings.highlight and H.raycastMarker and hover.coords and now - hover.coordsSeen < H.grace

        if entity and DoesEntityExist(entity) then
            if active ~= entity then
                active = entity
                min, max = GetModelDimensions(GetEntityModel(entity))
                nextInfo = 0
            end

            if H.boundingBox then drawBoxLines(entityBoxPoints(entity, min, max), ar, ag, ab, 255) end

            if H.axes then drawAxes(entity) end

            if H.infoLabel then
                if now >= nextInfo then
                    lines = buildInfo(entity)
                    nextInfo = now + 250
                end
                drawInfoPanel(GetOffsetFromEntityInWorldCoords(entity, 0.0, 0.0, max.z + 0.3), lines)
            end
        elseif active then
            active = nil
        end

        if ray then
            local c = hover.coords
            DrawMarker(28, c.x, c.y, c.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1, 0.1, 0.1, ar, ag, ab, 200, false, false, 2, false, nil, nil, false)
        end

        Wait((active or ray) and 0 or 150)
    end
end)

local pedBones = {'SKEL_ROOT', 'FB_R_Brow_Out_000', 'SKEL_L_Toe0', 'MH_R_Elbow', 'SKEL_L_Finger01', 'SKEL_L_Finger02', 'SKEL_L_Finger31', 'SKEL_L_Finger32', 'SKEL_L_Finger41', 'SKEL_L_Finger42', 'SKEL_L_Finger11', 'SKEL_L_Finger12', 'SKEL_L_Finger21', 'SKEL_L_Finger22', 'RB_L_ArmRoll', 'IK_R_Hand', 'RB_R_ThighRoll', 'SKEL_R_Clavicle', 'FB_R_Lip_Corner_000', 'SKEL_Pelvis', 'IK_Head', 'SKEL_L_Foot', 'MH_R_Knee', 'FB_LowerLipRoot_000', 'FB_R_Lip_Top_000', 'SKEL_L_Hand', 'FB_R_CheekBone_000', 'FB_UpperLipRoot_000', 'FB_L_Lip_Top_000', 'FB_LowerLip_000', 'SKEL_R_Toe0', 'FB_L_CheekBone_000', 'MH_L_Elbow', 'SKEL_Spine0', 'RB_L_ThighRoll', 'PH_R_Foot', 'SKEL_Spine1', 'SKEL_Spine2', 'SKEL_Spine3', 'FB_L_Eye_000', 'SKEL_L_Finger00', 'SKEL_L_Finger10', 'SKEL_L_Finger20', 'SKEL_L_Finger30', 'SKEL_L_Finger40', 'FB_R_Eye_000', 'SKEL_R_Forearm', 'PH_R_Hand', 'FB_L_Lip_Corner_000', 'SKEL_Head', 'IK_R_Foot', 'RB_Neck_1', 'IK_L_Hand', 'SKEL_R_Calf', 'RB_R_ArmRoll', 'FB_Brow_Centre_000', 'SKEL_Neck_1', 'SKEL_R_UpperArm', 'FB_R_Lid_Upper_000', 'RB_R_ForeArmRoll', 'SKEL_L_UpperArm', 'FB_L_Lid_Upper_000', 'MH_L_Knee', 'FB_Jaw_000', 'FB_L_Lip_Bot_000', 'FB_Tongue_000', 'FB_R_Lip_Bot_000', 'SKEL_R_Thigh', 'SKEL_R_Foot', 'IK_Root', 'SKEL_R_Hand', 'SKEL_Spine_Root', 'PH_L_Foot', 'SKEL_L_Thigh', 'FB_L_Brow_Out_000', 'SKEL_R_Finger00', 'SKEL_R_Finger10', 'SKEL_R_Finger20', 'SKEL_R_Finger30', 'SKEL_R_Finger40', 'PH_L_Hand', 'RB_L_ForeArmRoll', 'SKEL_L_Forearm', 'FB_UpperLip_000', 'SKEL_L_Calf', 'SKEL_R_Finger01', 'SKEL_R_Finger02', 'SKEL_R_Finger31', 'SKEL_R_Finger32', 'SKEL_R_Finger41', 'SKEL_R_Finger42', 'SKEL_R_Finger11', 'SKEL_R_Finger12', 'SKEL_R_Finger21', 'SKEL_R_Finger22', 'SKEL_L_Clavicle', 'FACIAL_facialRoot', 'IK_L_Foot'}

local vehicleBones = {'chassis', 'chassis_lowlod', 'chassis_dummy', 'seat_dside_f', 'seat_dside_r', 'seat_dside_r1', 'seat_dside_r2', 'seat_dside_r3', 'seat_dside_r4', 'seat_dside_r5', 'seat_dside_r6', 'seat_dside_r7', 'seat_pside_f', 'seat_pside_r', 'seat_pside_r1', 'seat_pside_r2', 'seat_pside_r3', 'seat_pside_r4', 'seat_pside_r5', 'seat_pside_r6', 'seat_pside_r7', 'window_lf1', 'window_lf2', 'window_lf3', 'window_rf1', 'window_rf2', 'window_rf3', 'window_lr1', 'window_lr2', 'window_lr3', 'window_rr1', 'window_rr2', 'window_rr3', 'door_dside_f', 'door_dside_r', 'door_pside_f', 'door_pside_r', 'handle_dside_f', 'handle_dside_r', 'handle_pside_f', 'handle_pside_r', 'wheel_lf', 'wheel_rf', 'wheel_lm1', 'wheel_rm1', 'wheel_lm2', 'wheel_rm2', 'wheel_lm3', 'wheel_rm3', 'wheel_lr', 'wheel_rr', 'suspension_lf', 'suspension_rf', 'suspension_lm', 'suspension_rm', 'suspension_lr', 'suspension_rr', 'spring_rf', 'spring_lf', 'spring_rr', 'spring_lr', 'transmission_f', 'transmission_m', 'transmission_r', 'hub_lf', 'hub_rf', 'hub_lm1', 'hub_rm1', 'hub_lm2', 'hub_rm2', 'hub_lm3', 'hub_rm3', 'hub_lr', 'hub_rr', 'windscreen', 'windscreen_r', 'window_lf', 'window_rf', 'window_lr', 'window_rr', 'window_lm', 'window_rm', 'bodyshell', 'bumper_f', 'bumper_r', 'wing_rf', 'wing_lf', 'bonnet', 'boot', 'exhaust', 'exhaust_2', 'exhaust_3', 'exhaust_4', 'exhaust_5', 'exhaust_6', 'exhaust_7', 'exhaust_8', 'exhaust_9', 'exhaust_10', 'exhaust_11', 'exhaust_12', 'exhaust_13', 'exhaust_14', 'exhaust_15', 'exhaust_16', 'engine', 'overheat', 'overheat_2', 'petrolcap', 'petroltank', 'petroltank_l', 'petroltank_r', 'steering', 'hbgrip_l', 'hbgrip_r', 'headlight_l', 'headlight_r', 'taillight_l', 'taillight_r', 'indicator_lf', 'indicator_rf', 'indicator_lr', 'indicator_rr', 'brakelight_l', 'brakelight_r', 'brakelight_m', 'reversinglight_l', 'reversinglight_r', 'extralight_1', 'extralight_2', 'extralight_3', 'extralight_4', 'numberplate', 'interiorlight', 'siren1', 'siren2', 'siren3', 'siren4', 'siren5', 'siren6', 'siren7', 'siren8', 'siren9', 'siren10', 'siren11', 'siren12', 'siren13', 'siren14', 'siren15', 'siren16', 'siren17', 'siren18', 'siren19', 'siren20', 'siren_glass1', 'siren_glass2', 'siren_glass3', 'siren_glass4', 'siren_glass5', 'siren_glass6', 'siren_glass7', 'siren_glass8', 'siren_glass9', 'siren_glass10', 'siren_glass11', 'siren_glass12', 'siren_glass13', 'siren_glass14', 'siren_glass15', 'siren_glass16', 'siren_glass17', 'siren_glass18', 'siren_glass19', 'siren_glass20', 'spoiler', 'struts', 'misc_a', 'misc_b', 'misc_c', 'misc_d', 'misc_e', 'misc_f', 'misc_g', 'misc_h', 'misc_i', 'misc_j', 'misc_k', 'misc_l', 'misc_m', 'misc_n', 'misc_o', 'misc_p', 'misc_q', 'misc_r', 'misc_s', 'misc_t', 'misc_u', 'misc_v', 'misc_w', 'misc_x', 'misc_y', 'misc_z', 'misc_1', 'misc_2', 'weapon_1a', 'weapon_1b', 'weapon_1c', 'weapon_1d', 'weapon_1a_rot', 'weapon_1b_rot', 'weapon_1c_rot', 'weapon_1d_rot', 'weapon_2a', 'weapon_2b', 'weapon_2c', 'weapon_2d', 'weapon_2a_rot', 'weapon_2b_rot', 'weapon_2c_rot', 'weapon_2d_rot', 'weapon_3a', 'weapon_3b', 'weapon_3c', 'weapon_3d', 'weapon_3a_rot', 'weapon_3b_rot', 'weapon_3c_rot', 'weapon_3d_rot', 'weapon_4a', 'weapon_4b', 'weapon_4c', 'weapon_4d', 'weapon_4a_rot', 'weapon_4b_rot', 'weapon_4c_rot', 'weapon_4d_rot', 'turret_1base', 'turret_1barrel', 'turret_2base', 'turret_2barrel', 'turret_3base', 'turret_3barrel', 'ammobelt', 'searchlight_base', 'searchlight_light', 'attach_female', 'roof', 'roof2', 'soft_1', 'soft_2', 'soft_3', 'soft_4', 'soft_5', 'soft_6', 'soft_7', 'soft_8', 'soft_9', 'soft_10', 'soft_11', 'soft_12', 'soft_13', 'forks', 'mast', 'carriage', 'fork_l', 'fork_r', 'forks_attach', 'frame_1', 'frame_2', 'frame_3', 'frame_pickup_1', 'frame_pickup_2', 'frame_pickup_3', 'frame_pickup_4', 'freight_cont', 'freight_bogey', 'freightgrain_slidedoor', 'door_hatch_r', 'door_hatch_l', 'tow_arm', 'tow_mount_a', 'tow_mount_b', 'tipper', 'combine_reel', 'combine_auger', 'slipstream_l', 'slipstream_r', 'arm_1', 'arm_2', 'arm_3', 'arm_4', 'scoop', 'boom', 'stick', 'bucket', 'shovel_2', 'shovel_3', 'Lookat_UpprPiston_head', 'Lookat_LowrPiston_boom', 'Boom_Driver', 'cutter_driver', 'vehicle_blocker', 'extra_1', 'extra_2', 'extra_3', 'extra_4', 'extra_5', 'extra_6', 'extra_7', 'extra_8', 'extra_9', 'extra_ten', 'extra_11', 'extra_12', 'break_extra_1', 'break_extra_2', 'break_extra_3', 'break_extra_4', 'break_extra_5', 'break_extra_6', 'break_extra_7', 'break_extra_8', 'break_extra_9', 'break_extra_10', 'mod_col_1', 'mod_col_2', 'mod_col_3', 'mod_col_4', 'mod_col_5', 'handlebars', 'forks_u', 'forks_l', 'wheel_f', 'swingarm', 'wheel_r', 'crank', 'pedal_r', 'pedal_l', 'static_prop', 'moving_prop', 'static_prop2', 'moving_prop2', 'rudder', 'rudder2', 'wheel_rf1_dummy', 'wheel_rf2_dummy', 'wheel_rf3_dummy', 'wheel_rb1_dummy', 'wheel_rb2_dummy', 'wheel_rb3_dummy', 'wheel_lf1_dummy', 'wheel_lf2_dummy', 'wheel_lf3_dummy', 'wheel_lb1_dummy', 'wheel_lb2_dummy', 'wheel_lb3_dummy', 'bogie_front', 'bogie_rear', 'rotor_main', 'rotor_rear', 'rotor_main_2', 'rotor_rear_2', 'elevators', 'tail', 'outriggers_l', 'outriggers_r', 'rope_attach_a', 'rope_attach_b', 'prop_1', 'prop_2', 'elevator_l', 'elevator_r', 'rudder_l', 'rudder_r', 'prop_3', 'prop_4', 'prop_5', 'prop_6', 'prop_7', 'prop_8', 'rudder_2', 'aileron_l', 'aileron_r', 'airbrake_l', 'airbrake_r', 'wing_l', 'wing_r', 'wing_lr', 'wing_rr', 'engine_l', 'engine_r', 'nozzles_f', 'nozzles_r', 'afterburner', 'wingtip_1', 'wingtip_2', 'gear_door_fl', 'gear_door_fr', 'gear_door_rl1', 'gear_door_rr1', 'gear_door_rl2', 'gear_door_rr2', 'gear_door_rml', 'gear_door_rmr', 'gear_f', 'gear_rl', 'gear_lm1', 'gear_rr', 'gear_rm1', 'gear_rm', 'prop_left', 'prop_right', 'legs', 'attach_male', 'draft_animal_attach_lr', 'draft_animal_attach_rr', 'draft_animal_attach_lm', 'draft_animal_attach_rm', 'draft_animal_attach_lf', 'draft_animal_attach_rf', 'wheelcover_l', 'wheelcover_r', 'barracks', 'pontoon_l', 'pontoon_r', 'no_ped_col_step_l', 'no_ped_col_strut_1_l', 'no_ped_col_strut_2_l', 'no_ped_col_step_r', 'no_ped_col_strut_1_r', 'no_ped_col_strut_2_r', 'light_cover', 'emissives', 'neon_l', 'neon_r', 'neon_f', 'neon_b', 'dashglow', 'doorlight_lf', 'doorlight_rf', 'doorlight_lr', 'doorlight_rr', 'unknown_id', 'dials', 'engineblock', 'bobble_head', 'bobble_base', 'bobble_hand', 'chassis_Control'}

local boneSession = 0

local function debugBones(entity, duration)
    if not entity or not DoesEntityExist(entity) then return end
    boneSession += 1
    local session = boneSession
    local isVehicle = GetEntityType(entity) == 2
    local names = isVehicle and vehicleBones or pedBones
    local markerType, markerSize, labelZ, labelScale = 23, 0.2, 0.03, 0.30
    if isVehicle then markerType, markerSize, labelZ, labelScale = 28, 0.15, 0.15, 0.25 end
    local bones = {}

    for i = 1, #names do
        local index = GetEntityBoneIndexByName(entity, names[i])
        if index ~= -1 then
            bones[#bones + 1] = { index = index, name = names[i] }
        end
    end
    if #bones == 0 then return end

    local endTime = GetGameTimer() + (duration or 10000)
    CreateThread(function()
        while session == boneSession and GetGameTimer() < endTime do
            Wait(0)
            if not DoesEntityExist(entity) then break end

            for i = 1, #bones do
                local bone = bones[i]
                local coords = GetWorldPositionOfEntityBone(entity, bone.index)

                DrawMarker(
                    markerType,
                    coords.x, coords.y, coords.z,
                    0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0,
                    markerSize, markerSize, markerSize,
                    255, 0, 0, 150,
                    false, false, 2, false, nil, nil, false
                )

                local onScreen, screenX, screenY = World3dToScreen2d(coords.x, coords.y, coords.z + labelZ)
                if onScreen then
                    SetTextScale(0.0, labelScale)
                    SetTextFont(0)
                    SetTextProportional(1)
                    SetTextColour(255, 255, 255, 215)
                    SetTextEntry('STRING')
                    SetTextCentre(1)
                    AddTextComponentString(bone.name .. ' - ' .. tostring(bone.index))
                    DrawText(screenX, screenY)
                end
            end
        end
    end)
end

local function buildInstructions()
    local scaleform = RequestScaleformMovie('instructional_buttons')
    while not HasScaleformMovieLoaded(scaleform) do Wait(0) end

    local hints = {
        { 7, { 172, 173, 174, 175 }, 'Move' },
        { 6, { 38, 44 }, 'Up / Down' },
        { 5, { 241, 242 }, 'Size' },
        { 4, { 21, 241 }, 'Height' },
        { 3, { 47, 74 }, 'Rotate' },
        { 2, { 36 }, 'Slow' },
        { 1, { 191 }, 'Create (Save)' },
        { 0, { 200 }, 'Exit' },
    }

    PushScaleformMovieFunction(scaleform, 'CLEAR_ALL')
    PopScaleformMovieFunctionVoid()
    PushScaleformMovieFunction(scaleform, 'SET_CLEAR_SPACE')
    PushScaleformMovieFunctionParameterInt(200)
    PopScaleformMovieFunctionVoid()

    for i = 1, #hints do
        PushScaleformMovieFunction(scaleform, 'SET_DATA_SLOT')
        PushScaleformMovieFunctionParameterInt(hints[i][1])
        for _, ctrl in ipairs(hints[i][2]) do
            ScaleformMovieMethodAddParamPlayerNameString(GetControlInstructionalButton(2, ctrl, true))
        end
        BeginTextCommandScaleformString('STRING')
        AddTextComponentScaleform(hints[i][3])
        EndTextCommandScaleformString()
        PopScaleformMovieFunctionVoid()
    end

    PushScaleformMovieFunction(scaleform, 'DRAW_INSTRUCTIONAL_BUTTONS')
    PopScaleformMovieFunctionVoid()
    PushScaleformMovieFunction(scaleform, 'SET_BACKGROUND_COLOUR')
    for _, v in ipairs({ 0, 0, 0, 80 }) do PushScaleformMovieFunctionParameterInt(v) end
    PopScaleformMovieFunctionVoid()
    return scaleform
end

local function held(key)
    return IsControlPressed(0, key) or IsDisabledControlPressed(0, key)
end

local function vec3str(v)
    return ('vec3(%.4f, %.4f, %.4f)'):format(v.x, v.y, v.z)
end

local function vec4str(v, heading)
    return ('vec4(%.4f, %.4f, %.4f, %.4f)'):format(v.x, v.y, v.z, heading)
end

local editorDisabled = { 14, 15, 16, 17, 38, 44, 47, 74, 200, 241, 242 }

local function zoneEditor(shape, origin, onDone, entity)
    if editorActive then return end
    editorActive = true

    local zone = { shape = shape, width = 1.0, height = 1.0, rotation = 0.0, coords = vec3(origin.x, origin.y, origin.z + 0.5) }
    local min, max
    if entity then
        zone.coords = vec3(origin.x, origin.y, origin.z)
        zone.rotation = GetEntityHeading(entity)
        min, max = GetModelDimensions(GetEntityModel(entity))
    end

    CreateThread(function()
        local scaleform = buildInstructions()
        local saved = false
        while true do
            Wait(0)
            DrawScaleformMovieFullscreen(scaleform, 255, 255, 255, 255, 0)
            for i = 1, #editorDisabled do DisableControlAction(0, editorDisabled[i], true) end

            if IsDisabledControlJustPressed(0, 200) then break end
            if IsControlJustPressed(0, 191) then
                saved = true
                break
            end

            local dt = GetFrameTime()
            local slow = held(36) and 0.25 or 1.0
            local camRad = math.rad(GetGameplayCamRot(2).z)
            local forward = vec3(-math.sin(camRad), math.cos(camRad), 0.0)
            local right = vec3(math.cos(camRad), math.sin(camRad), 0.0)

            local h = (IsControlPressed(0, 175) and 1 or 0) - (IsControlPressed(0, 174) and 1 or 0)
            local v = (IsControlPressed(0, 172) and 1 or 0) - (IsControlPressed(0, 173) and 1 or 0)
            local up = (held(38) and 1 or 0) - (held(44) and 1 or 0)
            local spin = (held(74) and 1 or 0) - (held(47) and 1 or 0)
            local wheel = (IsDisabledControlJustPressed(0, 241) and 1 or 0) - (IsDisabledControlJustPressed(0, 242) and 1 or 0)

            zone.coords += (right * h + forward * v + vec3(0.0, 0.0, up)) * (1.5 * dt * slow)

            if wheel ~= 0 and not entity then
                local step = 0.1 * (slow < 1.0 and 0.25 or 1.0)
                if held(21) and shape == 'box' then
                    local newHeight = math.max(0.1, zone.height + wheel * step)
                    zone.coords += vec3(0.0, 0.0, (newHeight - zone.height) / 2)
                    zone.height = newHeight
                else
                    zone.width = math.max(0.1, zone.width + wheel * step)
                    if shape == 'sphere' then zone.height = zone.width end
                end
            end

            if spin ~= 0 and shape ~= 'sphere' then
                zone.rotation = (zone.rotation + spin * 90.0 * dt * slow) % 360.0
            end

            if entity then
                SetEntityCoordsNoOffset(entity, zone.coords.x, zone.coords.y, zone.coords.z, false, false, false)
                SetEntityHeading(entity, zone.rotation)
                drawBoxLines(entityBoxPoints(entity, min, max), ar, ag, ab, 255)
            elseif shape == 'sphere' then
                DrawMarker(28, zone.coords.x, zone.coords.y, zone.coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, zone.width, zone.width, zone.width, ar, ag, ab, 160, false, false, 2, false, nil, nil, false)
            else
                drawBoxLines(zoneBoxPoints(zone.coords, zone.width, zone.height, zone.rotation), ar, ag, ab, 255)
            end

            local label = entity and ('Heading %.0f'):format(zone.rotation) or shape == 'box'
                and ('Size %.2f x %.2f x %.2f  |  Rot %.0f'):format(zone.width, zone.width, zone.height, zone.rotation)
                or ('Radius %.2f'):format(zone.width / 2)
            drawText3D(vec3(zone.coords.x, zone.coords.y, zone.coords.z + zone.height / 2 + 0.25), label, 255, 255, 255, 0.3)
        end

        while IsDisabledControlPressed(0, 200) do
            DisableControlAction(0, 200, true)
            Wait(0)
        end
        SetScaleformMovieAsNoLongerNeeded(scaleform)
        editorActive = false
        if onDone then onDone(zone, saved) end
    end)
end

local function targetDialog(title)
    local input = lib.inputDialog(title, {
        { type = 'input', label = 'Name:', required = true, default = 'Debug target' },
        { type = 'number', label = 'Distance:', required = true, min = 0.5, max = 10, default = 1.5 },
        { type = 'input', label = 'Icon:', required = true, default = 'hand' },
        { type = 'color', label = 'Icon color:', required = true, default = Config.Color },
        { type = 'textarea', label = 'onSelect:', required = true, autosize = true, default = "print('onSelect')" },
    })
    if not input then return end
    return { name = input[1], distance = input[2], icon = input[3], color = input[4], code = input[5] }
end

local function targetOption(t, name)
    return {
        name = name,
        label = t.name,
        icon = 'fas fa-' .. t.icon,
        distance = t.distance,
        iconColor = t.color,
        onSelect = function()
            lib.alertDialog({ header = '[DEBUG] - ' .. t.name, content = 'This is target debug alert.', centered = true, cancel = true })
        end,
    }
end

local function optionSnippet(t)
    return ([[{
        label = '%s',
        icon = 'fas fa-%s',
        distance = %s,
        iconColor = '%s',
        onSelect = function(data)
            %s
        end
    }]]):format(t.name, t.icon, t.distance, t.color, t.code)
end

local globalTargets = {
    Ped = {
        add = function(o) exports.ox_target:addGlobalPed(o) end,
        remove = function(n) exports.ox_target:removeGlobalPed(n) end,
    },
    Vehicle = {
        add = function(o) exports.ox_target:addGlobalVehicle(o) end,
        remove = function(n) exports.ox_target:removeGlobalVehicle(n) end,
    },
    Object = {
        add = function(o) exports.ox_target:addGlobalObject(o) end,
        remove = function(n) exports.ox_target:removeGlobalObject(n) end,
    },
    Player = {
        add = function(o) exports.ox_target:addGlobalPlayer(o) end,
        remove = function(n) exports.ox_target:removeGlobalPlayer(n) end,
    },
}

local function createTarget(kind, t, data)
    local name = 'nv_debug_' .. GetGameTimer()
    local option = targetOption(t, name)
    local body = optionSnippet(t)
    local snippet, remove

    if kind == 'box' then
        local id = exports.ox_target:addBoxZone({ coords = data.coords, size = data.size, rotation = data.rotation, debug = true, options = { option } })
        remove = function() exports.ox_target:removeZone(id) end
        snippet = ('exports.ox_target:addBoxZone({\n    coords = %s,\n    size = %s,\n    rotation = %.1f,\n    options = { %s }\n})'):format(vec3str(data.coords), vec3str(data.size), data.rotation, body)
    elseif kind == 'sphere' then
        local id = exports.ox_target:addSphereZone({ coords = data.coords, radius = data.radius, debug = true, options = { option } })
        remove = function() exports.ox_target:removeZone(id) end
        snippet = ('exports.ox_target:addSphereZone({\n    coords = %s,\n    radius = %.2f,\n    options = { %s }\n})'):format(vec3str(data.coords), data.radius, body)
    elseif kind == 'model' then
        exports.ox_target:addModel({ data.model }, { option })
        remove = function() exports.ox_target:removeModel({ data.model }, name) end
        local ref = type(data.model) == 'number' and tostring(data.model) or ("'%s'"):format(data.model)
        snippet = ('exports.ox_target:addModel({ %s }, { %s })'):format(ref, body)
    elseif kind == 'localEntity' then
        exports.ox_target:addLocalEntity({ data.entity }, { option })
        remove = function() exports.ox_target:removeLocalEntity({ data.entity }, name) end
        snippet = ('exports.ox_target:addLocalEntity(entity, { %s })'):format(body)
    else
        globalTargets[kind].add({ option })
        remove = function() globalTargets[kind].remove({ name }) end
        snippet = ('exports.ox_target:addGlobal%s({ %s })'):format(kind, body)
    end

    debugTargets[#debugTargets + 1] = remove
    copy('-- [TARGET] ' .. t.name .. '\n' .. snippet, 'Target code copied.')
end

local function targetFlow(title, kind, data)
    local t = targetDialog(title)
    if t then createTarget(kind, t, data) end
end

local function zoneTargetFlow(shape, origin)
    zoneEditor(shape, origin, function(zone, saved)
        if not saved then return end
        local t = targetDialog(shape == 'box' and 'Create Box Zone Target' or 'Create Sphere Zone Target')
        if not t then return end
        if shape == 'box' then
            createTarget('box', t, { coords = zone.coords, size = vec3(zone.width, zone.width, zone.height), rotation = zone.rotation })
        else
            createTarget('sphere', t, { coords = zone.coords, radius = zone.width / 2 })
        end
    end)
end

local function clearDebugTargets()
    for i = #debugTargets, 1, -1 do
        debugTargets[i]()
        debugTargets[i] = nil
    end
    showNotification('Success', 'Debug targets removed.')
end

local function spawn(kind, default, creator)
    local input = lib.inputDialog('Spawn ' .. kind, { { type = 'input', label = kind .. ' model:', placeholder = default } })
    if not input then return end
    local name = orDefault(input[1], default)
    local hash = loadModel(name)
    if not hash then return showNotification('Error', kind .. ' model not found') end
    creator(hash, raycastCoords, name)
    SetModelAsNoLongerNeeded(hash)
    showNotification('Success', kind .. ' created.')
end

local function opt(title, icon, onSelect, extra)
    local o = { title = title, icon = icon, iconColor = Config.Color, onSelect = onSelect }
    if extra then for k, v in pairs(extra) do o[k] = v end end
    return o
end

local function stay(menuId, fn)
    return function()
        fn()
        lib.showContext(menuId)
    end
end

local function onEntity(fn, menuId)
    return function()
        local entity = selectedEntity
        if not entity or not DoesEntityExist(entity) then
            selectedEntity = nil
            return showNotification('Error', 'Entity no longer exists.')
        end
        selectionBusy = true
        local ok, err = pcall(fn, entity)
        selectionBusy = false
        if not ok then error(err, 0) end
        if menuId and selectedEntity then lib.showContext(menuId) end
    end
end

local function clearSelection()
    selectedEntity = nil
end

local DANGER = { iconColor = Config.DangerColor }

local function registerMenus()
    local entity = selectedEntity
    local etype = (entity and DoesEntityExist(entity)) and GetEntityType(entity) or 0
    local hasTarget = targetEntity and DoesEntityExist(targetEntity)

    local function entityItem(title, icon, fn, menuId, extra)
        return opt(title, icon, onEntity(fn, menuId), extra)
    end

    local function copyItem(title, icon, label, getter)
        return entityItem(title, icon, function(e) copy(getter(e), label) end, 'entityInfoMenu')
    end

    local function vehicleItem(title, icon, fn)
        return entityItem(title, icon, function(e)
            if not control(e) then return showNotification('Error', 'Could not take control of the vehicle.') end
            fn(e)
        end, 'entityMenu')
    end

    local function pedItem(title, icon, fn, extra)
        return entityItem(title, icon, fn, 'entityMenu', extra)
    end

    local items = {}
    local function add(o) items[#items + 1] = o end

    if etype == 2 then
        add(opt('Vehicle Bones', 'bone', onEntity(function(e) debugBones(e, 10000) end)))
        add(opt('Change color', 'palette', nil, { menu = 'vehicleMenuColor' }))
        add(entityItem('Fuel level', 'gas-pump', function(e)
            local input = lib.inputDialog('Fuel level', { { type = 'number', label = 'Fuel level (0-100):', default = 100, required = true, min = 0, max = 100 } })
            if not input then return end
            control(e)
            SetVehicleFuelLevel(e, input[1] + 0.0)
            showNotification('Success', 'Fuel set: ' .. input[1] .. '%')
        end, 'entityMenu'))
        add(vehicleItem('Fix', 'gear', function(e)
            SetVehicleFixed(e)
            SetVehicleDeformationFixed(e)
            SetVehicleDirtLevel(e, 0.0)
            SetVehicleEngineHealth(e, 1000.0)
            SetVehiclePetrolTankHealth(e, 1000.0)
            showNotification('Success', 'Vehicle fixed.')
        end))
        add(vehicleItem('Toggle engine', 'power-off', function(e)
            local on = not GetIsVehicleEngineRunning(e)
            SetVehicleEngineOn(e, on, true, true)
            showNotification('Success', 'Engine: ' .. tostring(on))
        end))
        add(vehicleItem('Toggle doors lock', 'key', function(e)
            local locked = GetVehicleDoorLockStatus(e) > 1
            SetVehicleDoorsLocked(e, locked and 1 or 2)
            showNotification('Success', 'Doors locked: ' .. tostring(not locked))
        end))
        add(vehicleItem('Warp inside', 'right-to-bracket', function(e)
            TaskWarpPedIntoVehicle(cache.ped, e, IsVehicleSeatFree(e, -1) and -1 or -2)
        end))
    elseif etype == 1 then
        add(opt('Ped Bones', 'bone', onEntity(function(e) debugBones(e, 10000) end)))
        add(pedItem('Give weapon', 'gun', function(e)
            local rifle = joaat('weapon_assaultrifle')
            GiveWeaponToPed(e, rifle, 255, false, true)
            GiveWeaponToPed(e, joaat('weapon_pistol'), 255, false, true)
            SetCurrentPedWeapon(e, rifle, true)
            showNotification('Success', 'Assault rifle + Pistol added.')
        end))
        add(pedItem('Ragdoll Ped', 'person', function(e)
            SetPedToRagdoll(e, 20000, 20000, 0, false, false, false)
            showNotification('Success', 'Ped ragdoll for 20 seconds')
        end))
        add(pedItem('Heal Ped', 'heart', function(e)
            SetEntityHealth(e, GetEntityMaxHealth(e))
            showNotification('Success', 'Ped healed.')
        end))
        add(pedItem('Clear All Tasks', 'stop', function(e)
            ClearPedTasks(e)
            showNotification('Success', 'All task stopped.')
        end))
        add(pedItem('Play animation', 'film', function(e)
            local input = lib.inputDialog('Animations', {
                { type = 'input', label = 'Dictionary name:', placeholder = Config.Defaults.animDict },
                { type = 'input', label = 'Animation name:', placeholder = Config.Defaults.anim },
            })
            if not input then return end
            local dict = orDefault(input[1], Config.Defaults.animDict)
            local name = orDefault(input[2], Config.Defaults.anim)
            if not loadAnimDict(dict) then return showNotification('Error', "That animation doesn't exist.") end
            ClearPedTasksImmediately(e)
            TaskPlayAnim(e, dict, name, 8.0, -8.0, -1, 0, 0, false, false, false)
        end))
        add(pedItem('Play scenario', 'play', function(e)
            local input = lib.inputDialog('Scenarios', { { type = 'input', label = 'Scenario name:', placeholder = Config.Defaults.scenario } })
            if not input then return end
            local scenario = orDefault(input[1], Config.Defaults.scenario)
            ClearPedTasksImmediately(e)
            TaskStartScenarioInPlace(e, scenario, 0)
            showNotification('Success', 'Scenario: ' .. scenario)
        end))
        add(pedItem('Kill Ped', 'skull', function(e)
            SetEntityHealth(e, 0)
            showNotification('Success', 'Ped killed.')
        end, DANGER))
    end

    add(opt('Entity info', 'circle-info', nil, { menu = 'entityInfoMenu' }))
    add(entityItem('Freeze position', 'lock', function(e)
        control(e)
        local frozen = IsEntityPositionFrozen(e)
        FreezeEntityPosition(e, not frozen)
        showNotification('Success', 'Entity frozen: ' .. tostring(not frozen))
    end, 'entityMenu'))
    add(entityItem('Set Visibility', 'eye', function(e)
        local input = lib.inputDialog('Change Alpha', { { type = 'number', label = 'Alpha:', default = 255, required = true, min = 0, max = 255 } })
        if not input then return end
        control(e)
        if input[1] >= 255 then ResetEntityAlpha(e) else SetEntityAlpha(e, input[1], false) end
        showNotification('Success', 'Entity alpha: ' .. input[1])
    end, 'entityMenu'))
    add(opt('Teleport to entity', 'location-crosshairs', onEntity(function(e) teleport(GetEntityCoords(e)) end)))
    add(opt('Delete entity', 'trash', onEntity(function(e)
        if GetEntityType(e) == 1 and IsPedAPlayer(e) then return showNotification('Error', 'You cannot delete a player.') end
        local name = modelName(e)
        control(e)
        SetEntityAsMissionEntity(e, true, true)
        DeleteEntity(e)
        selectedEntity = nil
        showNotification('Success', 'Entity removed: ' .. name)
    end), DANGER))

    local colorOptions = {}
    for _, c in ipairs(Config.VehicleColors) do
        colorOptions[#colorOptions + 1] = entityItem(c.label .. ' color', 'droplet', function(e)
            if control(e) then SetVehicleColours(e, c.id, c.id) end
        end, 'vehicleMenuColor', { iconColor = c.color })
    end

    local travelOptions = {}
    for _, p in ipairs(Config.FastTravel) do
        travelOptions[#travelOptions + 1] = opt(p.label, 'location-dot', function() teleport(p.coords) end)
    end

    local function targetItem(title, icon, kind, dialogTitle, data)
        return opt(title, icon, stay('targetMenu', function() targetFlow(dialogTitle, kind, data) end))
    end

    local targetOptions = {
        opt('Box Zone Target', 'square', function() zoneTargetFlow('box', raycastCoords) end),
        opt('Sphere Zone Target', 'circle', function() zoneTargetFlow('sphere', raycastCoords) end),
    }

    if hasTarget then
        local model = GetEntityArchetypeName(targetEntity)
        if model == '' then model = GetEntityModel(targetEntity) end
        targetOptions[#targetOptions + 1] = targetItem('Local Entity Target', 'crosshairs', 'localEntity', 'Create Local Entity Target', { entity = targetEntity })
        targetOptions[#targetOptions + 1] = targetItem('Model Target', 'cube', 'model', 'Create Model Target', { model = model })
    else
        targetOptions[#targetOptions + 1] = opt('Local Entity Target', 'crosshairs', nil, { disabled = true, description = 'Aim at an entity' })
        targetOptions[#targetOptions + 1] = opt('Model Target', 'cube', nil, { disabled = true, description = 'Aim at an entity' })
    end

    for _, kind in ipairs({ 'Ped', 'Vehicle', 'Object', 'Player' }) do
        targetOptions[#targetOptions + 1] = targetItem('Global ' .. kind .. ' Target', 'globe', kind, 'Create Global ' .. kind .. ' Target')
    end
    targetOptions[#targetOptions + 1] = opt('Remove debug targets', 'eraser', stay('targetMenu', clearDebugTargets), { description = #debugTargets .. ' active' })

    local contexts = {
        {
            id = 'entityMenu',
            title = (typeNames[etype] or 'Entity') .. ' Menu',
            onExit = clearSelection,
            options = items,
        },
        {
            id = 'entityInfoMenu',
            title = 'Entity Information',
            menu = 'entityMenu',
            onExit = clearSelection,
            options = {
                copyItem('Copy Model Name', 'font', 'Model name.', modelName),
                copyItem('Copy Model Hash', 'hashtag', 'Model hash.', GetEntityModel),
                copyItem('Copy Position (vec3)', 'arrows-up-down-left-right', 'Entity vec3.', function(e) return vec3str(GetEntityCoords(e)) end),
                copyItem('Copy Position (vec4)', 'location-dot', 'Entity vec4.', function(e) return vec4str(GetEntityCoords(e), GetEntityHeading(e)) end),
                copyItem('Copy Rotation (vec3)', 'rotate', 'Entity rotation vec3.', function(e) return vec3str(GetEntityRotation(e, 2)) end),
                copyItem('Copy Heading (number)', 'rotate-left', 'Entity heading.', function(e) return ('%.4f'):format(GetEntityHeading(e)) end),
            },
        },
        {
            id = 'vehicleMenuColor',
            title = 'Change Vehicle Color',
            menu = 'entityMenu',
            onExit = clearSelection,
            options = colorOptions,
        },
        {
            id = 'playerMenu',
            title = 'Player Menu',
            options = {
                opt('Player Bones', 'bone', function() debugBones(cache.ped, 10000) end),
                opt('Heal yourself', 'heart', stay('playerMenu', function()
                    SetEntityHealth(cache.ped, GetEntityMaxHealth(cache.ped))
                end)),
                opt('Kill yourself', 'skull', function() SetEntityHealth(cache.ped, 0) end, DANGER),
                opt('Godmode', 'shield', stay('playerMenu', function()
                    godmode = not godmode
                    SetEntityInvincible(cache.ped, godmode)
                    showNotification('Success', 'Godmode: ' .. tostring(godmode))
                end), { description = godmode and 'Enabled' or 'Disabled' }),
                opt('Invisibility', 'ghost', stay('playerMenu', function()
                    invisible = not invisible
                    SetEntityVisible(cache.ped, not invisible, false)
                    showNotification('Success', 'Invisible: ' .. tostring(invisible))
                end), { description = invisible and 'Enabled' or 'Disabled' }),
                opt('Highlight', 'lightbulb', stay('playerMenu', function()
                    settings.highlight = not settings.highlight
                    showNotification('Success', 'Highlight: ' .. tostring(settings.highlight))
                end), { description = settings.highlight and 'Enabled' or 'Disabled' }),
                opt('Copy my position (vec3)', 'copy', stay('playerMenu', function()
                    copy(vec3str(GetEntityCoords(cache.ped)), 'Your vec3.')
                end)),
                opt('Copy my position (vec4)', 'copy', stay('playerMenu', function()
                    copy(vec4str(GetEntityCoords(cache.ped), GetEntityHeading(cache.ped)), 'Your vec4.')
                end)),
                opt('Teleport', 'map', function()
                    local input = lib.inputDialog('Teleport', { { type = 'input', label = 'Location:', placeholder = 'vec3(0.0, 0.0, 0.0)', required = true, max = 256 } })
                    if not input then return lib.showContext('playerMenu') end
                    local coords = parseCoords(input[1])
                    if not coords then
                        showNotification('Error', 'Invalid coordinates.')
                        return lib.showContext('playerMenu')
                    end
                    teleport(coords)
                end),
                opt('Teleport to waypoint', 'map-pin', teleportToWaypoint),
                opt('Fast travel', 'wand-sparkles', nil, { menu = 'fastTravel' }),
            },
        },
        {
            id = 'fastTravel',
            title = 'Fast Travel',
            menu = 'playerMenu',
            options = travelOptions,
        },
        {
            id = 'raycastMenu',
            title = 'Raycast Menu',
            options = {
                opt('Copy Position (vec3)', 'copy', stay('raycastMenu', function()
                    copy(vec3str(raycastCoords), 'Raycast vec3 copied.')
                end)),
                opt('Teleport here', 'location-crosshairs', function() teleport(raycastCoords) end),
                opt('Spawn ped', 'person', stay('raycastMenu', function()
                    spawn('Ped', Config.Defaults.ped, function(hash, c)
                        CreatePed(0, hash, c.x, c.y, c.z, GetEntityHeading(cache.ped) + 180.0, true, true)
                    end)
                end)),
                opt('Spawn vehicle', 'car', stay('raycastMenu', function()
                    spawn('Vehicle', Config.Defaults.vehicle, function(hash, c)
                        CreateVehicle(hash, c.x, c.y, c.z, GetEntityHeading(cache.ped) + 90.0, true, true)
                    end)
                end)),
                opt('Create object', 'box', function()
                    spawn('Object', Config.Defaults.object, function(hash, c, modelId)
                        local obj = CreateObject(hash, c.x, c.y, c.z, false, false)
                        PlaceObjectOnGroundProperly(obj)
                        FreezeEntityPosition(obj, true)
                        SetEntityCollision(obj, false, false)
                        zoneEditor('object', GetEntityCoords(obj), function(zone, saved)
                            if not DoesEntityExist(obj) then return end
                            if not saved then return DeleteEntity(obj) end
                            SetEntityCollision(obj, true, true)
                            local snippet = ([[
local model = joaat('%s')
lib.requestModel(model)
local coords = %s
local object = CreateObject(model, coords.x, coords.y, coords.z, false, false)
SetEntityHeading(object, coords.w)
FreezeEntityPosition(object, true)
SetModelAsNoLongerNeeded(model)]]):format(modelId, vec4str(zone.coords, zone.rotation))
                            copy(snippet, 'Create object code copied.')
                        end, obj)
                    end)
                end),
            },
        },
        {
            id = 'targetMenu',
            title = 'Target Menu',
            options = targetOptions,
        },
    }

    for _, ctx in ipairs(contexts) do
        if ctx.menu then table.insert(ctx.options, 1, opt('Back', 'arrow-left', nil, { menu = ctx.menu })) end
    end

    lib.registerContext(contexts)
end

local function nearPlayer(coords)
    return coords and #(GetEntityCoords(cache.ped) - coords) <= Config.Distance
end

local function entityOption(label, icon, etype)
    return {
        label = label, icon = icon, iconColor = Config.Color, distance = Config.Distance,
        canInteract = function(entity)
            if not entity or GetEntityType(entity) ~= etype then return false end
            hover.entity = entity
            hover.seen = GetGameTimer()
            return true
        end,
        onSelect = function(data)
            selectedEntity = data.entity
            if not selectedEntity or not DoesEntityExist(selectedEntity) then
                selectedEntity = nil
                return showNotification('Error', 'Entity not found')
            end
            registerMenus()
            lib.showContext('entityMenu')
        end,
    }
end

exports.ox_target:addGlobalOption({
    entityOption('Ped Menu', 'fas fa-person', 1),
    entityOption('Vehicle Menu', 'fas fa-car', 2),
    entityOption('Object Menu', 'fas fa-cube', 3),
    {
        label = 'Player Menu', icon = 'fas fa-user', iconColor = Config.Color, distance = Config.Distance,
        canInteract = function(_, _, coords)
            return nearPlayer(coords)
        end,
        onSelect = function()
            registerMenus()
            lib.showContext('playerMenu')
        end,
    },
    {
        label = 'Target Menu', icon = 'fas fa-bullseye', iconColor = Config.Color, distance = Config.Distance,
        canInteract = function(_, _, coords)
            return nearPlayer(coords)
        end,
        onSelect = function(data)
            raycastCoords = data.coords
            local e = data.entity
            targetEntity = (e and e ~= 0 and DoesEntityExist(e) and GetEntityType(e) > 0) and e or nil
            registerMenus()
            lib.showContext('targetMenu')
        end,
    },
    {
        label = 'Raycast Menu', icon = 'fas fa-arrows-to-dot', iconColor = Config.Color, distance = Config.Distance,
        canInteract = function(_, _, coords)
            if not nearPlayer(coords) then return false end
            hover.coords = coords
            hover.coordsSeen = GetGameTimer()
            return true
        end,
        onSelect = function(data)
            raycastCoords = data.coords
            registerMenus()
            lib.showContext('raycastMenu')
        end,
    },
})

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    if godmode then SetEntityInvincible(cache.ped, false) end
    if invisible then SetEntityVisible(cache.ped, true, false) end
end)
