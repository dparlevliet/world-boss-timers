-- ----------------------------------------------------------------------------
--  A persistent timer for World Bosses.
-- ----------------------------------------------------------------------------

-- addonName, addonTable = ...;
local _, WBT = ...;
WBT.addon_name = "WorldBossTimers";

--@do-not-package@
wbt_addon = WBT;
--@end-do-not-package@

local KillInfo = WBT.KillInfo;
local Util = WBT.Util;
local BossData = WBT.BossData;
local GUI = WBT.GUI;
local Config = WBT.Config;


WBT.AceAddon = LibStub("AceAddon-3.0"):NewAddon("WBT", "AceConsole-3.0");

-- Workaround to keep the nice WBT:Print function.
WBT.Print = function(self, text) WBT.AceAddon:Print(text) end

local gui = {};
local boss_death_frame;
local boss_combat_frame;
local g_kill_infos = {};

local CHANNEL_ANNOUNCE = "SAY";
local ICON_SKULL = "{skull}";
local SERVER_DEATH_TIME_PREFIX = "WorldBossTimers:";
local CHAT_MESSAGE_TIMER_REQUEST = "Could you please share WorldBossTimers kill data?";

local defaults = {
    global = {
        kill_infos = {},
        sound_enabled = true,
        sound_type = Config.SOUND_CLASSIC,
        auto_announce = true,
        send_data = true,
        cyclic = false,
        hide_gui = false,
    },
    char = {
        boss = {},
    },
};

function WBT.DebugPrint(...)
    print("DEBUG:", Util.MessageFromVarargs(...));
end

function WBT.IsDead(name)
    local ki = g_kill_infos[name];
    if ki and ki:IsValid() then
        return ki:IsDead();
    end
end
local IsDead = WBT.IsDead;

local function IsBoss(name)
    return Util.SetContainsKey(BossData.GetAll(), name);
end

local function GetCurrentMapId()
    return C_Map.GetBestMapForUnit("player");
end

function WBT.IsInZoneOfBoss(name)
    return GetCurrentMapId() == BossData.Get(name).map_id;
end

function WBT.BossInCurrentZone()
    for name, boss in pairs(BossData.GetAll()) do
        if WBT.IsInZoneOfBoss(name) then
            return boss;
        end
    end

    return nil;
end
local BossInCurrentZone = WBT.BossInCurrentZone;

local function IsInBossZone()
    return not not BossInCurrentZone();
end

local function GetKillInfoFromZone()
    local current_map_id = GetCurrentMapId();
    for name, boss_info in pairs(BossData.GetAll()) do
        if boss_info.map_id == current_map_id then
            return g_kill_infos[boss_info.name];
        end
    end

    return nil;
end

function WBT.GetSpawnTimeOutput(kill_info)
    local text = kill_info:GetSpawnTimeAsText();
    if kill_info.cyclic then
        text = Util.COLOR_RED .. text .. Util.COLOR_DEFAULT;
    end

    return text;
end
local GetSpawnTimeOutput = WBT.GetSpawnTimeOutput;

function WBT.IsBossZone()
    local current_map_id = GetCurrentMapId();

    local is_boss_zone = false;
    for name, boss in pairs(BossData.GetAll()) do
        if boss.map_id == current_map_id then
            is_boss_zone = true;
        end
    end

    return is_boss_zone;
end
local IsBossZone = WBT.IsBossZone;

function WBT.AnyDead()
    for name, boss in pairs(BossData.GetAll()) do
        if IsDead(name) then
            return true;
        end
    end
    return false;
end
local AnyDead = WBT.AnyDead;

local last_request_time = 0;
function WBT.RequestKillData()
    if GetServerTime() - last_request_time > 5 then
        SendChatMessage(CHAT_MESSAGE_TIMER_REQUEST, "SAY");
        last_request_time = GetServerTime();
    end
end
local RequestKillData = WBT.RequestKillData;

function WBT.GetColoredBossName(name)
    return BossData.Get(name).name_colored;
end
local GetColoredBossName = WBT.GetColoredBossName;

local function RegisterEvents()
    boss_death_frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED");
    boss_combat_frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED");
end

local function UnregisterEvents()
    boss_death_frame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED");
    boss_combat_frame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED");
end

function WBT.ResetBoss(name)
    local kill_info = g_kill_infos[name];

    if not kill_info.cyclic then
        local cyclic_mode = Util.COLOR_RED .. "Cyclid Mode" .. Util.COLOR_DEFAULT;
        WBT:Print("Clicking a world boss that is in " .. cyclic_mode .. " will reset it."
            .. " Try '/wbt cyclic' for more info.");
    else
        kill_info:Reset();
        gui:Update();
        WBT:Print(GetColoredBossName(name) .. " has been reset.");
    end
end

local function UpdateCyclicStates()
    for _, kill_info in pairs(g_kill_infos) do
        if kill_info:Expired() then
            kill_info.cyclic = true;
        end
    end
end

local function CreateServerDeathTimeParseable(kill_info, send_data_for_parsing)
    local t_death_parseable = "";
    if send_data_for_parsing then
        t_death_parseable = " (" .. SERVER_DEATH_TIME_PREFIX .. kill_info:GetServerDeathTime() .. ")";
    end

    return t_death_parseable;
end

local function CreateAnnounceMessage(kill_info, send_data_for_parsing)
    local spawn_time = kill_info:GetSpawnTimeAsText();
    local t_death_parseable = CreateServerDeathTimeParseable(kill_info, send_data_for_parsing);

    local msg = ICON_SKULL .. kill_info.name .. ICON_SKULL .. ": " .. spawn_time .. t_death_parseable;

    return msg;
end

function WBT.AnnounceSpawnTime(kill_info, send_data_for_parsing)
    SendChatMessage(CreateAnnounceMessage(kill_info, send_data_for_parsing), CHANNEL_ANNOUNCE, nil, nil);
end
local AnnounceSpawnTime = WBT.AnnounceSpawnTime;

local function SetKillInfo(name, t_death)
    t_death = tonumber(t_death);
    local ki = g_kill_infos[name];
    if ki then
        ki:SetNewDeath(name, t_death);
    else
        ki = KillInfo:New(t_death, name);
    end

    g_kill_infos[name] = ki;

    gui:Update();
end

local function InitDeathTrackerFrame()
    if boss_death_frame ~= nil then
        return
    end

    boss_death_frame = CreateFrame("Frame");
    boss_death_frame:SetScript("OnEvent", function(event, ...)
            local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName = CombatLogGetCurrentEventInfo();

            -- Convert to English name from GUID, to make it work for
            -- localization.
            local name = BossData.NameFromGuid(destGUID);
            if name == nil then
                return;
            end

            if eventType == "UNIT_DIED" then
                 SetKillInfo(name, GetServerTime());
                 gui:Update();
            end
        end);
end

local function PlayAlertSound(name)
    local sound_type = WBT.db.global.sound_type;
    local sound_enabled = WBT.db.global.sound_enabled;

    local soundfile = BossData.Get(name).soundfile;
    if sound_type:lower() == Config.SOUND_CLASSIC:lower() then
        soundfile = BossData.SOUND_FILE_DEFAULT;
    end

    if sound_enabled then
        PlaySoundFile(soundfile, "Master");
    end
end

local function InitCombatScannerFrame()
    if boss_combat_frame ~= nil then
        return
    end

    boss_combat_frame = CreateFrame("Frame");

    local time_out = 60*2; -- Legacy world bosses SHOULD die in this time.
    boss_combat_frame.t_next = 0;

    function boss_combat_frame:DoScanWorldBossCombat(event, ...)
		local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName = CombatLogGetCurrentEventInfo()

        -- Convert to English name from GUID, to make it work for
        -- localization.
        local name = BossData.NameFromGuid(destGUID);
        if name == nil then
            return;
        end

        local t = GetServerTime();
        if IsBoss(name) and t > self.t_next then
            WBT:Print(GetColoredBossName(name) .. " is now engaged in combat!");
            PlayAlertSound(name);
            FlashClientIcon();
            self.t_next = t + time_out;
        end
    end

    boss_combat_frame:SetScript("OnEvent", boss_combat_frame.DoScanWorldBossCombat);
end

function WBT.AceAddon:OnInitialize()
end

function WBT.PrintKilledBosses()
    WBT:Print("Tracked world bosses killed:");

    local none_killed_text = "None";
    local num_saved_world_bosses = GetNumSavedWorldBosses();
    if num_saved_world_bosses == 0 then
        WBT:Print(none_killed_text);
    else
        local none_killed = true;
        for i=1, num_saved_world_bosses do
            local name = GetSavedWorldBossInfo(i);
            if IsBoss(name) then
                none_killed = false;
                WBT:Print(GetColoredBossName(name))
            end
        end
        if none_killed then
            WBT:Print(none_killed_text);
        end
    end
end
local PrintKilledBosses = WBT.PrintKilledBosses;

function WBT.ResetKillInfo()
    WBT:Print("Resetting all kill info.");
    for _, kill_info in pairs(g_kill_infos) do
        kill_info:Reset();
    end

    gui:Update();
end
local ResetKillInfo = WBT.ResetKillInfo;

local function StartVisibilityHandler()
    local visibilty_handler_frame = CreateFrame("Frame");
    visibilty_handler_frame:RegisterEvent("ZONE_CHANGED_NEW_AREA");
    visibilty_handler_frame:SetScript("OnEvent",
        function(e, ...)
            gui:Update();
        end
    );
end

function WBT.AceAddon:InitChatParsing()

    local function InitRequestParsing()
        local function PlayerSentRequest(sender)
            -- Since \b and alike doesnt exist: use "frontier pattern": %f[%A]
            return string.match(sender, GetUnitName("player") .. "%f[%A]") ~= nil;
        end

        local request_parser = CreateFrame("Frame");
        local answered_requesters = {};
        request_parser:RegisterEvent("CHAT_MSG_SAY");
        request_parser:SetScript("OnEvent",
            function(self, event, msg, sender)
                if event == "CHAT_MSG_SAY" 
                        and msg == CHAT_MESSAGE_TIMER_REQUEST
                        and not Util.SetContainsKey(answered_requesters, sender)
                        and not PlayerSentRequest(sender) then

                    local boss = BossInCurrentZone();
                    if boss then
                        local kill_info = g_kill_infos[boss.name]
                        if kill_info and kill_info:IsCompletelySafe({}) then
                            AnnounceSpawnTime(kill_info, true);
                            answered_requesters[sender] = sender;
                        end
                    end
                end
            end
        );
    end

    local function InitSharedTimersParsing()
        local timer_parser = CreateFrame("Frame");
        timer_parser:RegisterEvent("CHAT_MSG_SAY");
        timer_parser:SetScript("OnEvent",
            function(self, event, msg, sender)
                if event == "CHAT_MSG_SAY" and string.match(msg, SERVER_DEATH_TIME_PREFIX) ~= nil then
                    local name, t_death = string.match(msg, ".*([A-Z][a-z]+).*" .. SERVER_DEATH_TIME_PREFIX .. "(%d+)");
                    if IsBoss(name) and not IsDead(name) then
                        SetKillInfo(name, t_death);
                        WBT:Print("Received " .. GetColoredBossName(name) .. " timer from: " .. sender);
                    end
                end
            end
        );
    end

    InitRequestParsing();
    InitSharedTimersParsing();
end

local function LoadSerializedKillInfos()
    for name, serialized in pairs(WBT.db.global.kill_infos) do
        g_kill_infos[name] = KillInfo:Deserialize(serialized);
    end
    
end

local function InitKillInfoManager()
    g_kill_infos = WBT.db.global.kill_infos;
    LoadSerializedKillInfos();

    kill_info_manager = CreateFrame("Frame");
    kill_info_manager.since_update = 0;
    local t_update = 1;
    kill_info_manager:SetScript("OnUpdate", function(self, elapsed)
            self.since_update = self.since_update + elapsed;
            if (self.since_update > t_update) then
                for _, kill_info in pairs(g_kill_infos) do
                    if kill_info:IsValid() then

                        kill_info:Update();

                        if kill_info.reset then
                            -- Do nothing.
                        else
                            if kill_info:ShouldAnnounce() then
                                AnnounceSpawnTime(kill_info, Config.send_data.get());
                            end

                            if kill_info:ShouldFlash() then
                                FlashClientIcon();
                            end

                            if kill_info:Expired() and Config.cyclic.get() then
                                local t_death_new, t_spawn = kill_info:EstimationNextSpawn();
                                kill_info.t_death = t_death_new
                                self.until_time = t_spawn;
                                kill_info.cyclic = true;
                            end
                        end
                    end
                end

                gui:Update();

                self.since_update = 0;
            end
        end);
end

function WBT.AceAddon:OnEnable()
    GUI.Init();

	WBT.db = LibStub("AceDB-3.0"):New("WorldBossTimersDB", defaults);
    GUI.SetupAceGUI();

    local AceConfig = LibStub("AceConfig-3.0");

    AceConfig:RegisterOptionsTable(WBT.addon_name, Config.optionsTable, {});
    WBT.AceConfigDialog = LibStub("AceConfigDialog-3.0");
    WBT.AceConfigDialog:AddToBlizOptions(WBT.addon_name, WBT.addon_name, nil);


    InitDeathTrackerFrame();
    InitCombatScannerFrame();
    if AnyDead() or IsBossZone() then
        RegisterEvents();
    end

    UpdateCyclicStates();

    InitKillInfoManager();

    gui = WBT.GUI:New();

    StartVisibilityHandler();

    self:RegisterChatCommand("wbt", Config.SlashHandler);
    self:RegisterChatCommand("worldbosstimers", Config.SlashHandler);

    self:InitChatParsing();

    RegisterEvents(); -- TODO: Update when this and unreg is called!
    -- UnregisterEvents();
end

function WBT.AceAddon:OnDisable()
end

--@do-not-package@
function d(min, sec)
    if not min then
        min = 17;
        sec = 55;
    end
    local decr = (60 * min + sec)
    local kill_info = g_kill_infos["Grellkin"];
    kill_info.t_death = kill_info.t_death - decr;
    kill_info.timer.until_time = kill_info.timer.until_time - decr;
end

local function start_sim(name, t)
    SetKillInfo(name, t);
end

function dsim()
    local function death_in_sec(name, t)
        return GetServerTime() - BossData.Get(name).max_respawn + t;
    end

    for name, data in pairs(BossData.GetAll()) do
        start_sim(name, death_in_sec(name, 4));
    end

end

-- Relog, and make sure it works after.
function dsim2()
    local function death_in_sec(name, t)
        return GetServerTime() - BossData.Get(name).max_respawn + t;
    end

    for name, data in pairs(BossData.GetAll()) do
        start_sim(name, death_in_sec(name, 25));
    end
end

function sim()
    start_sim(sha);
    start_sim(galleon);
end

function killsim()
    KillTag(g_kill_infos[galleon].timer, true);
    KillTag(g_kill_infos[sha].timer, true);
end

function reset()
    ResetKillInfo();
end

function test_KillInfo()
    local ki = WBT.KillInfo:New({name = "Testy",})
    ki:Print()
end
--@end-do-not-package@

