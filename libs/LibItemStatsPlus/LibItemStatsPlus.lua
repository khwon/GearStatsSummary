--[[

	Method:
	stats = lib:GetItemStats(itemlink);
	Returns: A table of item stats, as returns from API GetItemStats(itemlink).
	Including item's enchant, gems, reforged stats by scanning item's tooltip.
	
	===Additional Func===
	
	ilevel = lib:GetUpgradeLevel(itemlink)
	Returns: upgraded itemlevel of itemlink
	
	ratings = lib:GetRatingsFromStat(value, level, statName [, classid, specid] )
	Returns: Rating of statName from level in level
		-- TODO: add formula for resilience with DR in other levels
		-- TODO: handle different class and spec in mastery rather than lookup in db
	
	MeleeCritRating = lib:GetCritFromAgi(value, level, classid)
	SpellCritRating = lib:GetCritFromInt(value, level, classid)
	
	value = lib:GetAPFromAgi(value, classid)
	value = lib:GetAPFromStr(value, classid)
	value = lib:GetRAPFromAgi(value, classid)
	value = lib:GetMPFromSpt(value, classid)
	value = lib:GetHPFromSta(value, level)
	
	Struct for every gears stats
	
	stats = {	[statName1] = value,
				[statName2] = value,
				... 
				["Gems"] = 	{	["GemSlotCount"] = value,
								["EmptyGemSlotCount"] = value,
								["ExtraSlot"] = value, -- nil or 1 
							}
				["Enchanted"] = value, -- nil or 1
				["Set"] = 	{	[settext1] =  value, --designed for pvp power only
								[settext2] =  value,
								...
							}
			}
	
]]
local _, ns = ...
local MAJOR = "LibItemStatsPlus";
local MINOR = "$Revision: 3 $";
local debugmode = false

local lib = LibStub:NewLibrary(MAJOR, MINOR);
if not lib then return end

if debugmode then print(MAJOR.." "..MINOR.." loaded") end

local CombatRatingsFromIndexToName = ns.CombatRatingsFromIndexToName
local CombatRatingsFromNameToIndex = ns.CombatRatingsFromNameToIndex
local CombatRatingsFromRatingIDToIndex = ns.CombatRatingsFromRatingIDToIndex
local CombatRatings = ns.CombatRatings
--local CombatRating10 = ns.CombatRating10
--local CombatRating60 = ns.CombatRating60
local CritBase = ns.CritBase
local APPerStr = ns.APPerStr
local RAPPerAgi = ns.RAPPerAgi
local APPerAgi = ns.APPerAgi
local SPPerInt = ns.SPPerInt
local MPFromSpt = ns.MPFromSpt
local HpPerSta = ns.HpPerSta
local MasteryCoefficients = ns.MasteryCoefficients
local SpecIDToSpecIndex = ns.SpecIDToSpecIndex
local MeleeCritRatings = ns.MeleeCritRatings
local SpellCritRatings = ns.SpellCritRatings
local UpgradeLevels = ns.UpgradeLevels

local cache = {}
setmetatable(cache, {__mode = "kv"}) -- weak table to enable garbage collection

local tip = lib.tip
if not tip then
	-- Create a custom tooltip for scanning
	tip = CreateFrame("GameTooltip", MAJOR.."Tooltip", nil, "GameTooltipTemplate")
	lib.tip = tip
	tip:SetOwner(UIParent, "ANCHOR_NONE")
	for i = 1, 40 do
		tip[i] = _G[MAJOR.."TooltipTextLeft"..i]
		if not tip[i] then
			tip[i] = tip:CreateFontString()
			tip:AddFontStrings(tip[i], tip:CreateFontString())
			_G[MAJOR.."TooltipTextLeft"..i] = tip[i]
		end
	end
elseif not _G[MAJOR.."TooltipTextLeft40"] then
	for i = 1, 40 do
		_G[MAJOR.."TooltipTextLeft"..i] = tip[i]
	end
end

local GetClassIDFromClassName = {
	["WARRIOR"] = 1,
	["PALADIN"] = 2,
	["HUNTER"] = 3,
	["ROGUE"] = 4,
	["PRIEST"] = 5,
	["DEATHKNIGHT"] = 6,
	["SHAMAN"] = 7,
	["MAGE"] = 8,
	["WARLOCK"] = 9,
	["MONK"] = 10,
	["DRUID"] = 11,
}

local function CheckClassID(classid)
	if type(classid) ~= "number" then classid = GetClassIDFromClassName[classid] end
	if not classid then
		return
	else
		return classid
	end
end

local function GetStatIndex(statName)
	statIndex = CombatRatingsFromNameToIndex[statName]
	if statIndex == nil then statIndex = CombatRatingsFromRatingIDToIndex[statName] end
	return statIndex
end

local LOCALE_STHOUSAND = ",";  --Character used to separate groups of digits
local LOCALE_SDECIMAL = "."; --Character(s) used for the decimal separator
local patDecimal = "%d-[%"..LOCALE_STHOUSAND.."?%d]+%"..LOCALE_SDECIMAL.."?%d*"; --regex to find a localized decimal number e.g. 

local StatList = {
	["ITEM_MOD_STAMINA_SHORT"]=ITEM_MOD_STAMINA_SHORT,
	["ITEM_MOD_AGILITY_SHORT"]=ITEM_MOD_AGILITY_SHORT,
	["ITEM_MOD_INTELLECT_SHORT"]=ITEM_MOD_INTELLECT_SHORT,
	["ITEM_MOD_STRENGTH_SHORT"]=ITEM_MOD_STRENGTH_SHORT,
	["ITEM_MOD_SPIRIT_SHORT"]=ITEM_MOD_SPIRIT_SHORT,
	["ITEM_MOD_CRIT_RATING_SHORT"]=ITEM_MOD_CRIT_RATING_SHORT,
	["ITEM_MOD_DODGE_RATING_SHORT"]=ITEM_MOD_DODGE_RATING_SHORT,
	["ITEM_MOD_EXPERTISE_RATING_SHORT"]=ITEM_MOD_EXPERTISE_RATING_SHORT,
	["ITEM_MOD_HASTE_RATING_SHORT"]=ITEM_MOD_HASTE_RATING_SHORT,
	["ITEM_MOD_HIT_RATING_SHORT"]=ITEM_MOD_HIT_RATING_SHORT,
	["ITEM_MOD_MASTERY_RATING_SHORT"]=ITEM_MOD_MASTERY_RATING_SHORT,
	["ITEM_MOD_PARRY_RATING_SHORT"]=ITEM_MOD_PARRY_RATING_SHORT,
	["ITEM_MOD_RESILIENCE_RATING_SHORT"]=ITEM_MOD_RESILIENCE_RATING_SHORT,
	["ITEM_MOD_PVP_POWER_SHORT"]=ITEM_MOD_PVP_POWER_SHORT,
	["ITEM_MOD_SPELL_POWER_SHORT"]=ITEM_MOD_SPELL_POWER_SHORT,
	["SPELL_STATALL"]=SPELL_STATALL,
}

local GemSlots = {
	EMPTY_SOCKET = true,
	EMPTY_SOCKET_BLUE = true,
	EMPTY_SOCKET_COGWHEEL = true,
	EMPTY_SOCKET_HYDRAULIC = true,
	EMPTY_SOCKET_META = true,
	EMPTY_SOCKET_NO_COLOR = true,
	EMPTY_SOCKET_PRISMATIC = true,
	EMPTY_SOCKET_RED = true,
	EMPTY_SOCKET_YELLOW = true,
}

local Greycolor ={128/255, 128/255, 128/255}
local Whitecolor ={1, 1, 1}
local Greedcolor ={0, 1, 0}
local Yellocolor ={1, 210/255, 0}

function AddStats(stats, statName, value)
	value=string.gsub(value,",","")
	if stats[statName] == nil then
		stats[statName] = value
	else
		stats[statName] = stats[statName] + value
	end
	return stats
end

function ParseLine(stats, text, r, g, b)
	text = strtrim(text)
	if (ceil(r*255)==128) then return stats end --if color is grey then do nothing
	if strsub(text, -2) == "|r" then
		text = strsub(text, 1, -3)
	end
	if strfind(strsub(text, 1, 10), "|c%x%x%x%x%x%x%x%x") then
		text = strsub(text, 11)
	end

	--sets stats
	local found = string.find(text, ITEM_SET_BONUS:gsub("%%s",""));
	if found and (r==0 and ceil(g)==1 and b==0) then
	--print(text)
		local statName = "ITEM_MOD_PVP_POWER_SHORT"
		local statNameText = StatList[statName]
		found = string.find(string.upper(text), string.upper(statNameText));
		if found then
			local found, _, value = string.find(text, ".-("..patDecimal..").*");
			if found then
				if stats["Set"] == nil then stats["Set"] = {} end
				stats["Set"][text] = value:gsub(",","")
			end
		end
		return stats
	end

	--dual stats
	local found, _, value1, statNameStr1, value2, statNameStr2 = string.find(text, ".-%+("..patDecimal..")(.-)%+("..patDecimal..")(.*)");
	if found then
		for statName, statNameText in pairs(StatList) do
			if string.find(string.upper(statNameStr1), "^%s*"..string.upper(statNameText)) then
				AddStats(stats, statName, value1)
			end
			if string.find(string.upper(statNameStr2), "^%s*"..string.upper(statNameText)) then
				AddStats(stats, statName, value2)
			end
		end
		return stats
	end

	--single stats
	local found, _, value, statNameStr = string.find(text, ".-%+?("..patDecimal..")(.*)");
	if found then
		for statName, statNameText in pairs(StatList) do
			found = string.find(string.upper(statNameStr), "^%s*"..string.upper(statNameText));
			if found then
				if statName=="SPELL_STATALL" then
					AddStats(stats, "ITEM_MOD_STAMINA_SHORT", value)
					AddStats(stats, "ITEM_MOD_AGILITY_SHORT", value)
					AddStats(stats, "ITEM_MOD_INTELLECT_SHORT", value)
					AddStats(stats, "ITEM_MOD_STRENGTH_SHORT", value)
				else
					AddStats(stats, statName, value)
				end
			end
		end
		return stats
	end
	
	return stats
end

function AddGem(Gems, gem)
	if Gems[gem] == nil then
		Gems[gem] = 1
	else
		Gems[gem] = Gems[gem] + 1
	end
end

function lib:GetItemStats(itemlink, ...)
	if itemlink == nil then return 0 end
	if cache[itemlink] then
		return cache[itemlink]
	end
	local check, _, color, Ltype, Id, Enchant, Gem1, Gem2, Gem3, Gem4, Suffix, Unique, LinkLvl, Reforge, Upgrade, Name = string.find(itemlink, "|?c?f?f?(%x*)|?H?([^:]*):?(%d+):?(%d*):?(%d*):?(%d*):?(%d*):?(%d*):?(%-?%d*):?(%-?%d*):?(%d*):?(%d*):?(%d*)|?h?%[?([^%[%]c]*)%]?|?h?|?r?");
	if check == nil then return 0 end
	
	tip:ClearLines() -- this is required or SetX won't work the second time its called
	tip:SetHyperlink(itemlink)

	local stats = {}
	for i = 2, tip:NumLines() do
		local text = tip[i]:GetText();
		local r, g, b = tip[i]:GetTextColor()
		if debugmode then
			print(text)
		end
		ParseLine(stats, text, r, g, b);
	end --for each line in the tooltip

	------ func for GSS begin ------
	stats["Gems"] = {}
	stats["Gems"]["GemSlotCount"] = 0
 	for i = 1,4 do
 		local texture = _G[MAJOR.."TooltipTexture"..i]:GetTexture();
 		if ( texture ) then
			--if string.find(texture, "gem") then
				if debugmode then print(texture) end
				AddGem(stats["Gems"], "GemSlotCount")
				if string.find(texture, "EmptySocket") then
					AddGem(stats["Gems"], "EmptyGemSlotCount")
				end
			--end
	 	end
 	end
	
	local OriGemSlotCount = 0
	for k, v in next, GetItemStats(itemlink) do
		if(GemSlots[k]) then
			OriGemSlotCount = OriGemSlotCount + v
		end
	end
	if OriGemSlotCount < stats["Gems"]["GemSlotCount"] then
		stats["Gems"]["ExtraSlot"] = 1
	end

	for i = 1, 3 do
		local gemname, gemlink = GetItemGem(itemlink, i)
		if(gemlink) then
			local name, link, quality, iLevel, reqLevel, itype, subType = GetItemInfo(gemlink)
			AddGem(stats["Gems"], quality)
		end
	end
	
	if tonumber(Enchant) > 0 then --func for RS
		stats["Enchanted"] = 1
	end
	------ func for GSS end ------
	
	if debugmode then
		print(Name)
		for i,v in pairs(stats) do
			if v~=stats["Gems"] then print(i..","..v) end
		end
		print("------")	
	end

	return stats;
end


function lib:GetRatingsFromStat(value, level, statName, classid, specid)
	local statIndex, ratings
	statIndex = GetStatIndex(statName)
	if statIndex == nil or statIndex == 0 or type(value) ~= "number" then return 0 end
	--[[if ( level <= 60 ) and ( statIndex ~= 9 ) then
		if level < 10 then 
			ratings = value / CombatRating10[statIndex]
		else
			ratings = value / ( level * CombatRating60[statIndex][1] + CombatRating60[statIndex][2] )
		end
		return ratings
	elseif ( level <= 60 ) and ( level >= 10 ) then
		classid = CheckClassID(classid)
		if specid > 4 then
			specid = specid - SpecIDToSpecIndex[classid]
		end
		if not MasteryCoefficients[classid][specid] then return 0 end
		ratings = value / ( level * CombatRating60[statIndex][1] + CombatRating60[statIndex][2] ) * MasteryCoefficients[classid][specid]
		return ratings
	end]]
	if ( statIndex == 6 ) and  ( level == 90 ) then
		-- handle resilience with DR in lv 90
		-- TODO: add formula for resilience with DR in other levels
		-- more info here: http://www.icy-veins.com/forums/topic/303-combat-ratings-at-level-90-in-mists-of-pandaria/#pvp_resilience
		ratings = 100 - 100 * 0.99 ^ ( value / 310 )
	elseif ( statIndex == 9 ) then 
		-- TODO: handle different class and spec in mastery rather than lookup in db
		classid = CheckClassID(classid)
		if specid > 4 then
			specid = specid - SpecIDToSpecIndex[classid]
		end
		if not MasteryCoefficients[classid][specid] then return 0 end
		ratings = value / CombatRatings[level][statIndex] * MasteryCoefficients[classid][specid]
	else
		ratings = value / CombatRatings[level][statIndex]
	end
	return ratings
end

function lib:GetCritFromAgi(value, level, classid)
	if type(level) ~= "number" or type(value) ~= "number" then return 0 end
	classid = CheckClassID(classid)
	if level <= MAX_PLAYER_LEVEL and classid <= MAX_CLASSES then
		return value / MeleeCritRatings[level][classid]
	end
end

function lib:GetCritFromInt(value, level, classid)
	if type(level) ~= "number" or type(value) ~= "number" then return 0 end
	classid = CheckClassID(classid)
	if not classid then return 0 end
	return value / SpellCritRatings[level][classid]
end

function lib:GetAPFromAgi(value, classid)
	if type(value) ~= "number" then return 0 end
	classid = CheckClassID(classid)
	if not classid then return 0 end
	return value * APPerAgi[classid]
end

function lib:GetAPFromStr(value, classid)
	if type(value) ~= "number" then return 0 end
	classid = CheckClassID(classid)
	if not classid then return 0 end
	return value * APPerStr[classid]
end

function lib:GetRAPFromAgi(value, classid)
	if type(value) ~= "number" then return 0 end
	classid = CheckClassID(classid)
	if not classid then return 0 end
	return value * RAPPerAgi[classid]
end

function lib:GetSPFromInt(value, classid)
	if type(value) ~= "number" then return 0 end
	classid = CheckClassID(classid)
	if not classid then return 0 end
	return value * SPPerInt[classid]
end

function lib:GetMPFromSpt(value, classid)
	if type(value) ~= "number" then return 0 end
	classid = CheckClassID(classid)
	if not classid then return 0 end
	return value * MPPerSpt[classid]
end

function lib:GetHPFromSta(value, level)
	if type(level) ~= "number" or type(value) ~= "number" then return 0 end
	return value * HpPerSta[level]
end

function lib:GetUpgradeLevel(link)
	if not link then return 0 end
	local upgrade = link:match(":(%d+)\124h%[")
	local itemLevel = select(4, GetItemInfo(link)) 
	if itemLevel ~= nil then
		itemLevel = itemLevel + (UpgradeLevels[upgrade] or 0)
		return itemLevel
	end
end
