-- ULTRA LOW CPU v4.4
-- Локальная визуальная оптимизация.
-- Повторный запуск: восстановить настройки и выключить скрипт.
--
-- ВАЖНО:
-- ParticleEmitter:Clear() удаляет уже созданные частицы.
-- Они не восстанавливаются повторным запуском.

local ENV = _G

pcall(function()
    if type(getgenv) == "function" then
        local env = getgenv()
        if type(env) == "table" then
            ENV = env
        end
    end
end)

local ID = "__ULTRA_LOW_CPU_V44"
local previous = ENV[ID]

if type(previous) == "table"
    and type(previous.Restore) == "function" then

    local ok, err = pcall(function()
        previous:Restore()
    end)

    if not ok then
        warn("[ULTRA] Ошибка восстановления:", err)
    end

    return
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local LocalPlayer = Players.LocalPlayer

local CFG = {
    QUALITY_LEVEL = true,
    FPS_CAP = nil, -- Укажи 60 для ограничения FPS, если executor поддерживает его.

    HIDE_TEXTURES = true,
    LOW_MESH_DETAIL = true,

    DISABLE_PARTICLES = true,
    CLEAR_EXISTING_PARTICLES = true,

    DISABLE_POST_EFFECTS = true,
    DISABLE_LIGHTS = true,
    DISABLE_HIGHLIGHTS = true,
    DISABLE_SHADOWS = true,

    CLEAR_SKY = true,
    INVISIBLE_WATER = true,
    DISABLE_TERRAIN_DECORATION = true,

    OPTIMIZE_NEW_OBJECTS = true,
    PROTECT_LOCAL_PLAYER = true,

    BATCH_SIZE = 400,
}

local state = {
    active = true,

    saved = setmetatable({}, {__mode = "k"}),
    processed = setmetatable({}, {__mode = "k"}),

    -- Сильные ссылки нужны, пока SurfaceAppearance отсоединён.
    detachedSurfaces = {},

    hiddenProperties = setmetatable({}, {__mode = "k"}),

    connections = {},

    queue = {},
    queued = setmetatable({}, {__mode = "k"}),
    queueHead = 1,
    queueTail = 0,
    queueWorker = false,

    oldQuality = nil,
    oldFpsCap = nil,

    stats = {
        scanned = 0,
        changed = 0,
        failed = 0,
        skipped = 0,
        runtimeErrors = 0,
        restoreFailures = 0,
        particlesCleared = 0,
    },
}

-- Получаем executor-функцию, если она доступна.
local hiddenSetter

pcall(function()
    if type(sethiddenproperty) == "function" then
        hiddenSetter = sethiddenproperty
    end
end)

if not hiddenSetter and type(ENV.sethiddenproperty) == "function" then
    hiddenSetter = ENV.sethiddenproperty
end

local particleClasses = {
    ParticleEmitter = true,
    Trail = true,
    Beam = true,
    Smoke = true,
    Fire = true,
    Sparkles = true,
}

local skyTextures = {
    "SkyboxBk",
    "SkyboxDn",
    "SkyboxFt",
    "SkyboxLf",
    "SkyboxRt",
    "SkyboxUp",
}

local function isProtected(obj)
    if not CFG.PROTECT_LOCAL_PLAYER or not LocalPlayer then
        return false
    end

    local character = LocalPlayer.Character

    return character ~= nil
        and (obj == character or obj:IsDescendantOf(character))
end

-- Обычная запись с сохранением исходного значения.
local function setProp(obj, property, value)
    local okRead, oldValue = pcall(function()
        return obj[property]
    end)

    if not okRead then
        state.stats.failed += 1
        return false
    end

    if oldValue == value then
        return true
    end

    local props = state.saved[obj]

    if not props then
        props = {}
        state.saved[obj] = props
    end

    local hadSaved = props[property] ~= nil
    local oldSaved = props[property]

    if not hadSaved then
        props[property] = oldValue
    end

    local okWrite = pcall(function()
        obj[property] = value
    end)

    if okWrite then
        state.stats.changed += 1
        return true
    end

    state.stats.failed += 1

    if not hadSaved then
        props[property] = nil
    else
        props[property] = oldSaved
    end

    return false
end

-- Отдельная осторожная попытка записи Not Scriptable-свойства.
-- Работает только при наличии подходящей функции executor.
local function setHiddenProp(obj, property, value)
    if type(hiddenSetter) ~= "function" then
        state.stats.skipped += 1
        return false
    end

    local okRead, oldValue = pcall(function()
        return obj[property]
    end)

    if not okRead then
        state.stats.failed += 1
        return false
    end

    if oldValue == value then
        return true
    end

    local props = state.saved[obj]

    if not props then
        props = {}
        state.saved[obj] = props
    end

    local hadSaved = props[property] ~= nil
    local oldSaved = props[property]

    if not hadSaved then
        props[property] = oldValue
    end

    local okWrite, result = pcall(
        hiddenSetter, obj, property, value
    )

    if okWrite and result ~= false then
        local flags = state.hiddenProperties[obj]

        if not flags then
            flags = {}
            state.hiddenProperties[obj] = flags
        end

        flags[property] = true
        state.stats.changed += 1
        return true
    end

    state.stats.failed += 1

    if not hadSaved then
        props[property] = nil
    else
        props[property] = oldSaved
    end

    return false
end

-- Временно отключаем PBR-материал без попыток
-- записывать недоступные карты SurfaceAppearance.
local function detachSurface(obj)
    local parent = obj.Parent

    if not parent then
        return
    end

    local ok = pcall(function()
        obj.Parent = nil
    end)

    if ok then
        table.insert(state.detachedSurfaces, {
            object = obj,
            parent = parent,
        })

        state.stats.changed += 1
    else
        state.stats.failed += 1
    end
end

local function optimize(obj)
    if not state.active or state.processed[obj] then
        return
    end

    state.processed[obj] = true
    state.stats.scanned += 1

    local ok = pcall(function()
        if isProtected(obj) then
            return
        end

        local class = obj.ClassName

        -- Частицы и визуальные эффекты.
        if CFG.DISABLE_PARTICLES and particleClasses[class] then
            setProp(obj, "Enabled", false)

            if CFG.CLEAR_EXISTING_PARTICLES
                and class == "ParticleEmitter" then

                local clearOk = pcall(function()
                    obj:Clear()
                end)

                if clearOk then
                    state.stats.particlesCleared += 1
                else
                    state.stats.failed += 1
                end
            end

        elseif CFG.DISABLE_POST_EFFECTS
            and obj:IsA("PostEffect") then

            setProp(obj, "Enabled", false)

        elseif CFG.DISABLE_LIGHTS and obj:IsA("Light") then
            setProp(obj, "Enabled", false)

        elseif CFG.DISABLE_HIGHLIGHTS
            and class == "Highlight" then

            setProp(obj, "Enabled", false)

        -- PBR: отсоединяем объект, не меняя read-only карты.
        elseif CFG.HIDE_TEXTURES
            and class == "SurfaceAppearance" then

            detachSurface(obj)

        elseif CFG.HIDE_TEXTURES
            and (class == "Decal" or class == "Texture") then

            setProp(obj, "Transparency", 1)
            setProp(obj, "Texture", "")

        elseif CFG.HIDE_TEXTURES and class == "SpecialMesh" then
            setProp(obj, "TextureId", "")

        elseif CFG.HIDE_TEXTURES and class == "Shirt" then
            setProp(obj, "ShirtTemplate", "")

        elseif CFG.HIDE_TEXTURES and class == "Pants" then
            setProp(obj, "PantsTemplate", "")

        elseif CFG.HIDE_TEXTURES and class == "ShirtGraphic" then
            setProp(obj, "Graphic", "")

        elseif obj:IsA("BasePart") then
            if CFG.DISABLE_SHADOWS then
                setProp(obj, "CastShadow", false)
            end

            setProp(obj, "Reflectance", 0)

            if CFG.LOW_MESH_DETAIL and class == "MeshPart" then
                setProp(
                    obj,
                    "RenderFidelity",
                    Enum.RenderFidelity.Performance
                )

                if CFG.HIDE_TEXTURES then
                    setProp(obj, "TextureID", "")
                end
            end

        elseif CFG.CLEAR_SKY and class == "Atmosphere" then
            setProp(obj, "Density", 0)
            setProp(obj, "Haze", 0)
            setProp(obj, "Glare", 0)

        elseif CFG.CLEAR_SKY and class == "Clouds" then
            setProp(obj, "Cover", 0)
            setProp(obj, "Density", 0)

        elseif CFG.CLEAR_SKY and class == "Sky" then
            for _, property in ipairs(skyTextures) do
                setProp(obj, property, "")
            end

            setProp(obj, "CelestialBodiesShown", false)
            setProp(obj, "StarCount", 0)
        end
    end)

    if not ok then
        state.stats.runtimeErrors += 1
    end
end

-- Новые объекты обрабатываем очередью, пакетами.
-- Это уменьшает резкие всплески работы обработчика событий.
local function queueOptimize(obj)
    if not state.active
        or state.processed[obj]
        or state.queued[obj] then
        return
    end

    state.queued[obj] = true
    state.queueTail += 1
    state.queue[state.queueTail] = obj

    if state.queueWorker then
        return
    end

    state.queueWorker = true

    task.spawn(function()
        while state.active
            and state.queueHead <= state.queueTail do

            local processedInBatch = 0

            while state.active
                and state.queueHead <= state.queueTail
                and processedInBatch < CFG.BATCH_SIZE do

                local index = state.queueHead
                local item = state.queue[index]

                state.queue[index] = nil
                state.queueHead += 1
                processedInBatch += 1

                if item then
                    state.queued[item] = nil

                    if item.Parent then
                        optimize(item)
                    end
                end
            end

            task.wait()
        end

        state.queue = {}
        state.queueHead = 1
        state.queueTail = 0
        state.queueWorker = false
    end)
end

local function scan(root)
    if not state.active then
        return
    end

    local ok, descendants = pcall(function()
        return root:GetDescendants()
    end)

    if not ok then
        state.stats.failed += 1
        return
    end

    for i = 1, #descendants, CFG.BATCH_SIZE do
        if not state.active then
            return
        end

        local last = math.min(i + CFG.BATCH_SIZE - 1, #descendants)

        for j = i, last do
            optimize(descendants[j])
        end

        task.wait()
    end
end

-- Глобальные визуальные настройки.
if CFG.DISABLE_SHADOWS then
    setProp(Lighting, "GlobalShadows", false)
end

local terrain = Workspace:FindFirstChildOfClass("Terrain")

if terrain then
    if CFG.DISABLE_TERRAIN_DECORATION then
        -- Попытка только через executor API.
        -- В обычном LocalScript свойство недоступно для записи.
        setHiddenProp(terrain, "Decoration", false)
    end

    setProp(terrain, "WaterWaveSize", 0)
    setProp(terrain, "WaterWaveSpeed", 0)
    setProp(terrain, "WaterReflectance", 0)

    if CFG.INVISIBLE_WATER then
        setProp(terrain, "WaterTransparency", 1)
    end
end

-- Минимальное качество графики.
if CFG.QUALITY_LEVEL and type(settings) == "function" then
    local ok, rendering = pcall(function()
        return settings().Rendering
    end)

    if ok and rendering then
        local readOk, original = pcall(function()
            return rendering.QualityLevel
        end)

        if readOk then
            local writeOk = pcall(function()
                rendering.QualityLevel = Enum.QualityLevel.Level01
            end)

            if writeOk then
                state.oldQuality = original
            else
                state.stats.failed += 1
            end
        else
            state.stats.failed += 1
        end
    else
        state.stats.skipped += 1
    end
end

-- Необязательное ограничение FPS.
if type(CFG.FPS_CAP) == "number" and CFG.FPS_CAP > 0 then
    if type(getfpscap) == "function"
        and type(setfpscap) == "function" then

        local okGet, oldCap = pcall(getfpscap)

        if okGet then
            local okSet = pcall(setfpscap, CFG.FPS_CAP)

            if okSet then
                state.oldFpsCap = oldCap
            else
                state.stats.failed += 1
            end
        else
            state.stats.failed += 1
        end
    else
        state.stats.skipped += 1
    end
end

-- Подписываемся до сканирования: новые объекты не теряются.
if CFG.OPTIMIZE_NEW_OBJECTS then
    table.insert(
        state.connections,
        Workspace.DescendantAdded:Connect(queueOptimize)
    )

    table.insert(
        state.connections,
        Lighting.DescendantAdded:Connect(queueOptimize)
    )
end

function state:Restore()
    if not self.active then
        return
    end

    self.active = false

    for _, connection in ipairs(self.connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    self.connections = {}
    self.queue = {}

    -- Восстанавливаем обычные свойства и Not Scriptable-свойства.
    for obj, properties in pairs(self.saved) do
        for property, oldValue in pairs(properties) do
            local flags = self.hiddenProperties[obj]
            local wasHidden = flags and flags[property]

            local okRestore

            if wasHidden and type(hiddenSetter) == "function" then
                okRestore = pcall(
                    hiddenSetter, obj, property, oldValue
                )

                if not okRestore then
                    okRestore = pcall(function()
                        obj[property] = oldValue
                    end)
                end
            else
                okRestore = pcall(function()
                    obj[property] = oldValue
                end)
            end

            if not okRestore then
                self.stats.restoreFailures += 1
            end
        end
    end

    -- Возвращаем отсоединённые SurfaceAppearance.
    for i = #self.detachedSurfaces, 1, -1 do
        local item = self.detachedSurfaces[i]

        local okRestore = pcall(function()
            item.object.Parent = item.parent
        end)

        if not okRestore then
            self.stats.restoreFailures += 1
        end
    end

    -- Возвращаем исходное качество графики.
    if self.oldQuality ~= nil and type(settings) == "function" then
        local okRestore = pcall(function()
            settings().Rendering.QualityLevel = self.oldQuality
        end)

        if not okRestore then
            self.stats.restoreFailures += 1
        end
    end

    -- Возвращаем FPS cap, только если он был изменён.
    if self.oldFpsCap ~= nil and type(setfpscap) == "function" then
        local okRestore = pcall(setfpscap, self.oldFpsCap)

        if not okRestore then
            self.stats.restoreFailures += 1
        end
    end

    local summary = self.stats

    self.saved = setmetatable({}, {__mode = "k"})
    self.processed = setmetatable({}, {__mode = "k"})
    self.queued = setmetatable({}, {__mode = "k"})
    self.hiddenProperties = setmetatable({}, {__mode = "k"})
    self.detachedSurfaces = {}

    if ENV[ID] == self then
        ENV[ID] = nil
    end

    print(string.format(
        "[ULTRA] Восстановление завершено. Ошибок восстановления: %d. Ранее очищенных частиц не вернуть.",
        summary.restoreFailures
    ))
end

ENV[ID] = state

task.spawn(function()
    scan(Workspace)
    scan(Lighting)

    if state.active then
        print(string.format(
            "[ULTRA v4.4] Сканировано: %d | Изменений: %d | Ошибок: %d | Пропусков: %d | Очищено эмиттеров: %d",
            state.stats.scanned,
            state.stats.changed,
            state.stats.failed,
            state.stats.skipped,
            state.stats.particlesCleared
        ))
    end
end)

print("[ULTRA v4.4] Запущен. Повторный запуск вернёт сохранённые настройки.")
