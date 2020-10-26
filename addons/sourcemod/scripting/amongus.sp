/*
-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
tf-amongus: Among Us recreated within TF2

Sorry if the code is messy, this is my
second plugin and it's been quite an
ambitous project for myself and others.

Original Concept - IceboundCat6
Lead Development - MouseDroidPoW
SourcePawn Help - puntero


(Feel free to add your name here)
-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
*/

#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <morecolors>
#include <sdkhooks>
#include <tf2items>
#include <customkeyvalues>
#include <stocksoup/entity_prefabs>
#include <steamtools> //should we still undef extensions? no documentation...

#pragma semicolon 1
#pragma newdecls optional

#define SPY_MODEL "models/amongus/player/spy.mdl"
#define RECHARGE_SOUND "player/recharged.wav"
#define FOUNDBODY_SOUND "amongus/foundbody.mp3"
#define EMERGENCY_SOUND "amongus/emergencymeeting.mp3"
#define KILL_SOUND "amongus/kill.mp3"
#define SPAWN_SOUND "amongus/spawn.mp3"

// https://forums.alliedmods.net/showthread.php?t=229013

#define MAJOR_REVISION "0"
#define MINOR_REVISION "1"
#define STABLE_REVISION "9"
#define PLUGIN_VERSION MAJOR_REVISION..."."...MINOR_REVISION..."."...STABLE_REVISION

enum PlayerState
{
	State_Crewmate = 0, //the player can perform tasks but can't see who the impostor is
	State_Impostor, //the player cannot perform tasks but they can see other impostors and sabotage map-specific events (doors, etc)
	State_Ghost, //the player is considered dead and cannot be seen by the above but still has to perform tasks; can't see impostor or chat to "alive" players
	State_ImpostorGhost //the player is considered dead... you get the idea, they can still sabotage and see other impostors alongside seeing other ghosts
};

enum Reason
{
	Reason_NoMeeting = 0, //resume gameplay
	Reason_FoundBody, //a body was reported by the announcer
	Reason_EmergencyButton, //the announcer pushed the map-specific emergency button (not implemented yet)

	/* after VotingState_Voting and during VotingState_Ejection: */

	Reason_Anonymous, //someone was ejected but we don't know if it was an impostor or not (see sm_amongus_anonymousejection)
	Reason_Crewmate, //crewmate was ejected
	Reason_Impostor, //impostor was ejected
	Reason_Tie, //tie between one or more players; don't eject
	Reason_Skip, //skip won the highest votes
	Reason_Disconnected //player has left before voting could end
};

enum VotingState
{
	VotingState_NoVote = 0, //normal gameplay, this is what everything tugs onto for seeing the round state
	VotingState_PreVoting, //discussion time
	VotingState_Voting, //show ui and let players vote
	VotingState_Ejection, //this is used to show who was voted out (maybe teleport the players somewhere to see it?)
	VotingState_Generic, //also used to show who was voted out but only if the map is not tfau_theskeld
	VotingState_EndOfRound //just to make it easier to determine when the round has ended instead of making a RoundState enum
};

enum SkinSwitchType
{
	Skin_ChatColor = 0, //sets the char[] to the chat color of the client
	Skin_Name, //sets the char[] to color name of the client
	Skin_NameWithSkin, //sets the char[] to the color name of the int provided
	Skin_RenderColor //sets the client's render color to their respective color
};

enum GhostReason
{
	GhostReason_Killed = 0, //the player has been killed
	GhostReason_Suicide, //the player has died without an attacker
	GhostReason_Ejected, //the player has suffocated from being ejected into outer space
	GhostReason_Generic //the player has been killed but the map is not tfau_theskeld
};

enum RoundStart
{
	RoundStart_Ongoing = 0, //round isn't starting anymore; deny microphone/chat
	RoundStart_Starting, //round is starting; allow microphone/chat
	RoundStart_Ended, //round has ended; allow microphone/chat
	RoundStart_NotEnoughPlayers //not enough players to start; allow microphone/chat
};

enum VentState
{
	VentState_Crewmate = 0, //player is not allowed to use vents
	VentState_NoVent, //player is not using vents
	VentState_OnTopOfVent, //player is on top of a vent
	VentState_InsideVent //player is inside of a vent
};

enum EmergencyButtonState
{
	Emergency_NotNearButton = 0, //player cannot press button
	Emergency_NextToButton //player can press button
};


Reason currentMeeting = Reason_NoMeeting;
PlayerState playerState[MAXPLAYERS +1];
VotingState g_votingState = VotingState_NoVote;
RoundStart startOfRound = RoundStart_Ended;
VentState ventState[MAXPLAYERS +1];
EmergencyButtonState emergencyButton[MAXPLAYERS +1];

char voteAnnouncer[MAX_NAME_LENGTH];
char g_ventLocation1Name[MAX_NAME_LENGTH];
char g_ventLocation2Name[MAX_NAME_LENGTH];

int g_ventDoors[MAXPLAYERS +1] = -1;
int g_ventLocation1[MAXPLAYERS +1] = -1;
int g_ventLocation2[MAXPLAYERS +1] = -1;

int emergencyUses[MAXPLAYERS +1];
int g_knifeCount[MAXPLAYERS +1];
int g_playerSkin[MAXPLAYERS +1];
int activeImpostors = 0;
int voteCounter[MAXPLAYERS +1];
int alreadyVoted[MAXPLAYERS +1]; //0 or 1 please
int votePlayerCorelation[MAXPLAYERS +1]; //reverse: key = vote id, value = user id
int voteStorage[MAXPLAYERS +2]; //plus 1 extra because last slot will be used for skip
int firstVote; //used for ejection
int secondVote; //used to test for a tie
int iSkin = 0;
int mapEmergencyButtonId = -1;

Handle g_hHud;
Handle persistentUITimer[MAXPLAYERS +1]=INVALID_HANDLE;
Handle g_hWeaponEquip;

ConVar versionCvar;
ConVar knifeConVarCount;
ConVar requiredToStart;
ConVar impostorCount;
ConVar preVotingCount;
ConVar votingCount;
ConVar ejectionCount;
ConVar anonymousEjection;
ConVar emergencyButtonMaxUses;

ConVar friendlyFire;
ConVar unbalanceLimit;
ConVar forceAutoTeam;
ConVar autoTeamBalance;
ConVar allowSpectators;
ConVar restartGame;
ConVar voiceEnable;

ArrayList g_aSpawnPoints;

char resources[][] =
{
	//materials
	"materials/models/amongus/player/spy/eyeball_l.vmt",
	"materials/models/amongus/player/spy/eyeball_l.vtf",
	"materials/models/amongus/player/spy/eyeball_r.vmt",
	"materials/models/amongus/player/spy/eyeball_r.vtf",
	"materials/models/amongus/player/spy/spy_black.vmt",
	"materials/models/amongus/player/spy/spy_black.vtf",
	"materials/models/amongus/player/spy/spy_blue.vmt",
	"materials/models/amongus/player/spy/spy_blue.vtf",
	"materials/models/amongus/player/spy/spy_brown.vmt",
	"materials/models/amongus/player/spy/spy_brown.vtf",
	"materials/models/amongus/player/spy/spy_cyan.vmt",
	"materials/models/amongus/player/spy/spy_cyan.vtf",
	"materials/models/amongus/player/spy/spy_green.vmt",
	"materials/models/amongus/player/spy/spy_green.vtf",
	"materials/models/amongus/player/spy/spy_head_black.vmt",
	"materials/models/amongus/player/spy/spy_head_black.vtf",
	"materials/models/amongus/player/spy/spy_head_blue.vmt",
	"materials/models/amongus/player/spy/spy_head_blue.vtf",
	"materials/models/amongus/player/spy/spy_head_brown.vmt",
	"materials/models/amongus/player/spy/spy_head_brown.vtf",
	"materials/models/amongus/player/spy/spy_head_cyan.vmt",
	"materials/models/amongus/player/spy/spy_head_cyan.vtf",
	"materials/models/amongus/player/spy/spy_head_green.vmt",
	"materials/models/amongus/player/spy/spy_head_green.vtf",
	"materials/models/amongus/player/spy/spy_head_lime.vmt",
	"materials/models/amongus/player/spy/spy_head_lime.vtf",
	"materials/models/amongus/player/spy/spy_head_orange.vmt",
	"materials/models/amongus/player/spy/spy_head_orange.vtf",
	"materials/models/amongus/player/spy/spy_head_pink.vmt",
	"materials/models/amongus/player/spy/spy_head_pink.vtf",
	"materials/models/amongus/player/spy/spy_head_purple.vmt",
	"materials/models/amongus/player/spy/spy_head_purple.vtf",
	"materials/models/amongus/player/spy/spy_head_red.vmt",
	"materials/models/amongus/player/spy/spy_head_red.vtf",
	"materials/models/amongus/player/spy/spy_head_white.vmt",
	"materials/models/amongus/player/spy/spy_head_white.vtf",
	"materials/models/amongus/player/spy/spy_head_yellow.vmt",
	"materials/models/amongus/player/spy/spy_head_yellow.vtf",
	"materials/models/amongus/player/spy/spy_lime.vmt",
	"materials/models/amongus/player/spy/spy_lime.vtf",
	"materials/models/amongus/player/spy/spy_orange.vmt",
	"materials/models/amongus/player/spy/spy_orange.vtf",
	"materials/models/amongus/player/spy/spy_pink.vmt",
	"materials/models/amongus/player/spy/spy_pink.vtf",
	"materials/models/amongus/player/spy/spy_purple.vmt",
	"materials/models/amongus/player/spy/spy_purple.vtf",
	"materials/models/amongus/player/spy/spy_red.vmt",
	"materials/models/amongus/player/spy/spy_red.vtf",
	"materials/models/amongus/player/spy/spy_white.vmt",
	"materials/models/amongus/player/spy/spy_white.vtf",
	"materials/models/amongus/player/spy/spy_yellow.vmt",
	"materials/models/amongus/player/spy/spy_yellow.vtf",
	"materials/models/prop_dock/emergency_button.vmt",
	"materials/models/prop_dock/emergency_button.vtf",
	"materials/models/prop_dock/emergency_button_glass.vmt",
	"materials/models/prop_dock/emergency_button_glass.vmt",
	"materials/models/prop_dock/emergency_button2.vmt",
	"materials/models/prop_dock/emergency_button2.vmt",
	//audio
	"sound/amongus/emergencymeeting.mp3",
	"sound/amongus/foundbody.mp3",
	"sound/amongus/kill.mp3",
	"sound/amongus/spawn.mp3",
	//models
	"models/amongus/player/spy.dx80.vtx",
	"models/amongus/player/spy.dx90.vtx",
	"models/amongus/player/spy.mdl",
	"models/amongus/player/spy.phy",
	"models/amongus/player/spy.sw.vtx",
	"models/amongus/player/spy.vvd",
	"models/prop_dock/emergency_button01.dx80.vtx",
	"models/prop_dock/emergency_button01.dx90.vtx",
	"models/prop_dock/emergency_button01.mdl",
	"models/prop_dock/emergency_button01.sw.vtx",
	"models/prop_dock/emergency_button01.vvd",
	"models/prop_dock/emergency_button02.dx80.vtx",
	"models/prop_dock/emergency_button02.dx90.vtx",
	"models/prop_dock/emergency_button02.mdl",
	"models/prop_dock/emergency_button02.sw.vtx",
	"models/prop_dock/emergency_button02.vvd"
};

public Plugin myinfo =
{
	name = "[TF2] Among Us",
	author = "TeamPopplio, IceboundCat6, puntero",
	description = "Among Us in TF2!",
	version = PLUGIN_VERSION,
	url = "https://github.com/TeamPopplio/tf-amongus"
};

public void OnMapStart()
{
	PrecacheModel(SPY_MODEL, true);
	PrecacheSound(RECHARGE_SOUND, true);
	PrecacheSound(FOUNDBODY_SOUND, true);
	PrecacheSound(EMERGENCY_SOUND, true);
	PrecacheSound(KILL_SOUND, true);
	PrecacheSound(SPAWN_SOUND, true);
	int ent = -1;
	g_aSpawnPoints = new ArrayList();
	while((ent = FindEntityByClassname(ent, "info_player_teamspawn")) != -1)
	{
		g_aSpawnPoints.Push(ent); //set spawn locations in the map
	}
	while((ent = FindEntityByClassname(ent, "prop_dynamic")) != -1) //find the emergency button
	{
		char targetName[32];
		GetEntPropString(ent, Prop_Data, "m_iName", targetName, sizeof(targetName));
		if(StrContains(targetName,"emergency_button") != -1)
		{
			mapEmergencyButtonId = ent;
			break;
		}
	}
	for(int i = 0;i < sizeof(resources);i++)
		AddFileToDownloadsTable(resources[i]); //add resources
}

public OnConfigsExecuted()
{
	char gameDesc[64];
	Format(gameDesc, sizeof(gameDesc), "Among Us v%s", PLUGIN_VERSION);
	Steam_SetGameDescription(gameDesc);
}

public void OnPluginEnd()
{
	LogMessage("[TF2] Among Us - Unloading! (v%s)", PLUGIN_VERSION);
	for(new i = 1; i <= MaxClients; i++)
	{
		if(persistentUITimer[i] != INVALID_HANDLE)
		{
			KillTimer(persistentUITimer[i],false); //kill timer so changelevel doesn't break the plugin
		}
	}
}

public void OnPluginStart()
{
	LogMessage("[TF2] Among Us - Initalizing! (v%s)", PLUGIN_VERSION);

	// --- Variables

	char oldVersion[64];
	g_hHud = CreateHudSynchronizer();

	// --- Commands

	versionCvar = CreateConVar("sm_amongus_version", PLUGIN_VERSION, "Among Us version - do not modify!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_SPONLY|FCVAR_DONTRECORD);
	requiredToStart = CreateConVar("sm_amongus_requiredtostart", "3", "Sets the amount of players required to start the game.");
	impostorCount = CreateConVar("sm_amongus_impostorcount", "1", "Sets the amount of impostors that can be applied in a single game.");
	knifeConVarCount = CreateConVar("sm_amongus_knifecount", "20", "Sets how many seconds an impostor should wait before being able to use their knife.");
	preVotingCount = CreateConVar("sm_amongus_prevotingtimer", "30", "Sets how many seconds a vote should wait before starting.");
	votingCount = CreateConVar("sm_amongus_votingtimer", "30", "Sets how many seconds a vote should last before ejection.");
	ejectionCount = CreateConVar("sm_amongus_ejectiontimer", "10", "Sets how many seconds ejection should last.");
	anonymousEjection = CreateConVar("sm_amongus_anonymousejection", "0", "Enable (1) or disable (0) anonymous ejection.");
	emergencyButtonMaxUses = CreateConVar("sm_amongus_maxemergencies", "2", "Sets the maximum amount of emergencies a single player can call.");

	friendlyFire = FindConVar("mp_friendlyfire");
	unbalanceLimit = FindConVar("mp_teams_unbalance_limit");
	forceAutoTeam = FindConVar("mp_forceautoteam");
	autoTeamBalance = FindConVar("mp_autoteambalance");
	allowSpectators = FindConVar("mp_allowspectators");
	restartGame = FindConVar("mp_restartgame");
	voiceEnable = FindConVar("sv_voiceenable");

	RegAdminCmd("sm_amongus_becomeimpostor", Command_BecomeImpostor, ADMFLAG_SLAY|ADMFLAG_CHEATS, "sm_amongus_becomeimpostor <#userid|name>");
	RegAdminCmd("sm_amongus_restart", Command_Restart, ADMFLAG_SLAY|ADMFLAG_CHEATS, "sm_amongus_restart <crewmates|impostors|nobody>");

	// --- Hooks

	HookEvent("player_spawn", OnPlayerSpawn);
	HookEvent("teamplay_round_start", GameStart, EventHookMode_Pre);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
	HookEvent("player_sapped_object", Event_Sapped, EventHookMode_Post);

	HookEntityOutput("trigger_multiple", "OnStartTouch", OnTriggerMultiple);
	HookEntityOutput("trigger_multiple", "OnEndTouch", OnTriggerMultipleEnd);

	// --- Command Listeners

	AddCommandListener(Listener_Voice, "voicemenu");
	AddCommandListener(Listener_Chat, "say");
	AddCommandListener(Listener_Chat, "say_team");
	AddCommandListener(Listener_Death, "kill");
	AddCommandListener(Listener_Death, "explode");
	AddCommandListener(Listener_Death, "jointeam");
	AddCommandListener(Listener_Death, "joinclass");

	// --- Translations

	LoadTranslations("amongus.phrases");
	LoadTranslations("common.phrases");

	// --- Misc.

	voiceEnable.Flags &= ~FCVAR_NOTIFY; //disable serverwide "Server cvar ... changed to x"

	SetConVarBool(friendlyFire,true);
	SetConVarBool(unbalanceLimit,false);
	SetConVarBool(forceAutoTeam,false);
	SetConVarBool(autoTeamBalance,false);
	SetConVarBool(allowSpectators,false);
	SetConVarBool(voiceEnable,true);

	AutoExecConfig(true, "AmongUs");
	GetConVarString(versionCvar, oldVersion, sizeof(oldVersion));
	if(strcmp(oldVersion, PLUGIN_VERSION, false))
		PrintToServer("[TF2] Among Us - Your config may be outdated. Back up tf/cfg/sourcemod/AmongUs.cfg and delete it, this plugin will generate a new one that you can then modify to your original values.");

	//adding here for redundancy in case plugin is hotloaded
	if(g_aSpawnPoints == null)
	{
		int ent = -1;
		g_aSpawnPoints = new ArrayList();
		while((ent = FindEntityByClassname(ent, "info_player_teamspawn")) != -1)
		{
			g_aSpawnPoints.Push(ent);
		}
	}
}

//venting for impostor
// https://forums.alliedmods.net/showpost.php?p=2258820&postcount=4

public void OnTriggerMultiple(const String:output[], caller, activator, Float:delay) {
	char targetName[32];
	GetEntPropString(caller, Prop_Data, "m_iName", targetName, sizeof(targetName));
	if(StrContains(targetName, "trigger_emergencybutton", false) != -1 && IsValidClient(activator))
	{
		if (ventState[activator] != VentState_InsideVent && startOfRound == RoundStart_Ongoing && playerState[activator] != State_Ghost && playerState[activator] != State_ImpostorGhost && TF2_GetClientTeam(activator) == TFTeam_Red)
		{
			emergencyButton[activator] = Emergency_NextToButton;
		}
	}
	else if (StrContains(targetName, "vent_", false) != -1 && IsValidClient(activator))
	{
		if (ventState[activator] != VentState_Crewmate && TF2_GetClientTeam(activator) == TFTeam_Red)
		{
			int ent = -1;
			char ventDoor[MAX_NAME_LENGTH];
			char ventLoc1[MAX_NAME_LENGTH];
			char ventLoc2[MAX_NAME_LENGTH];
			ventState[activator] = VentState_OnTopOfVent;
			GetCustomKeyValue(caller, "ventdoor", ventDoor, sizeof(ventDoor));
			GetCustomKeyValue(caller, "ventlocation1", ventLoc1, sizeof(ventLoc1));
			GetCustomKeyValue(caller, "ventlocation2", ventLoc2, sizeof(ventLoc2));
			GetCustomKeyValue(caller, "ventlocation1_name", g_ventLocation1Name[activator], MAX_NAME_LENGTH);
			GetCustomKeyValue(caller, "ventlocation2_name", g_ventLocation2Name[activator], MAX_NAME_LENGTH);
			while ((ent = FindEntityByClassname(ent, "func_door")) != -1)
			{
				char door[MAX_NAME_LENGTH];
				GetEntPropString(ent, Prop_Data, "m_iName", door, sizeof(door));
				if(StrEqual(door,ventDoor))
					g_ventDoors[activator] = ent;
			}
			while ((ent = FindEntityByClassname(ent, "info_teleport_destination")) != -1)
			{
				char tele[MAX_NAME_LENGTH];
				GetEntPropString(ent, Prop_Data, "m_iName", tele, sizeof(tele));
				if(StrEqual(tele,ventLoc1))
					g_ventLocation1[activator] = ent;
				if(StrEqual(tele,ventLoc2))
					g_ventLocation2[activator] = ent;
			}
		}
	}
}

public void OnTriggerMultipleEnd(const String:output[], caller, activator, Float:delay) {
	char targetName[32];
	GetEntPropString(caller, Prop_Data, "m_iName", targetName, sizeof(targetName));
	if(StrContains(targetName, "trigger_emergencybutton", false) != -1 && IsValidClient(activator))
	{
		emergencyButton[activator] = Emergency_NotNearButton;
	}
	else if (StrContains(targetName, "vent_", false) != -1 && IsValidClient(activator))
	{
		if (ventState[activator] == VentState_OnTopOfVent && TF2_GetClientTeam(activator) == TFTeam_Red)
		{
			ventState[activator] = VentState_NoVent;
			g_ventDoors[activator] = -1;
			g_ventLocation1[activator] = -1;
			g_ventLocation2[activator] = -1;
		}
	}
}

public int VentHandler1 (Menu menu, MenuAction action, int client, int param2)
{
	char info[MAX_NAME_LENGTH];
	menu.GetItem(param2, info, sizeof(info));
	if (action == MenuAction_Select)
	{
		int votedFor = StringToInt(info);
		float seq1Origin[3];
		float seq1Angles[3];
		switch(votedFor)
		{
			case 1:
			{
				GetEntPropVector(g_ventLocation1[client], Prop_Send, "m_vecOrigin", seq1Origin);
				GetEntPropVector(g_ventLocation1[client], Prop_Send, "m_angRotation", seq1Angles);
				TeleportEntity(client,seq1Origin,seq1Angles,NULL_VECTOR);
			}
			case 2:
			{
				GetEntPropVector(g_ventLocation2[client], Prop_Send, "m_vecOrigin", seq1Origin);
				GetEntPropVector(g_ventLocation2[client], Prop_Send, "m_angRotation", seq1Angles);
				TeleportEntity(client,seq1Origin,seq1Angles,NULL_VECTOR);
			}
			default:
			{
				if(IsValidEntity(g_ventDoors[client]))
					AcceptEntityInput(g_ventDoors[client], "Open", -1, -1, -1);
				ventState[client] = VentState_OnTopOfVent;
				SetEntityMoveType(client, MOVETYPE_WALK);
			}
		}
		return 1;
	}
	return 0;
}

public void DrawVentPanels(client)
{
	Menu panel = new Menu(VentHandler1);
	panel.SetTitle("Vent");
	panel.AddItem("0", "Leave");
	panel.AddItem("1", g_ventLocation1Name[client]);
	if(!StrEqual(g_ventLocation1Name[client],""))
		panel.AddItem("2", g_ventLocation2Name[client]);
	panel.ExitButton = false;
	if(IsValidClient(client) && ventState[client] == VentState_InsideVent)
	{
		panel.Display(client,1000);
	}
}

//this is just base code for tasks when they get added
// https://forums.alliedmods.net/showthread.php?p=1329948
public Action Event_Sapped(Handle:event, const String:name[], bool:dontBroadcast)
{
	//ownerid is gonna be an invalid client because it's a map placed entity
	int sapper = GetEventInt(event, "sapperid");
	if(IsValidEntity(sapper))
		AcceptEntityInput(sapper, "Kill");
}

//when players call medic or any other voice commands
public Action Listener_Voice(client, const String:command[], argc)
{
	if(playerState[client] == State_Ghost || playerState[client] == State_ImpostorGhost)
		return Plugin_Handled;
	
	switch(ventState[client])
	{
		case VentState_OnTopOfVent:
		{
			if(IsValidEntity(g_ventDoors[client]))
				AcceptEntityInput(g_ventDoors[client], "Open", -1, -1, -1);
			ventState[client] = VentState_InsideVent;
			SetEntityMoveType(client, MOVETYPE_NONE);
		}
		default:
		{
			switch(emergencyButton[client])
			{
				case Emergency_NextToButton:
				{
					DrawEmergencyPanel(client);
				}
				default:
				{
					int entity = GetClientAimTarget(client, false);
					char targetname[128];
					int skin;
					char classname[MAX_NAME_LENGTH];

					if (IsValidEntity(entity))
					{
						GetEntPropString(entity, Prop_Data, "m_iClassname", classname, sizeof(classname));
						if(StrEqual(classname,"prop_dynamic"))
						{
							GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
							skin = GetEntProp(entity, Prop_Data, "m_nSkin");
							if(StrEqual(targetname,"deadbody",true))
							{
								if(g_votingState == VotingState_NoVote)
								{
									AcceptEntityInput(entity, "ClearParent");
									AcceptEntityInput(entity, "Kill");
									StartMeeting(client, Reason_FoundBody, skin);
								}
							}
						}
					}
				}
			}
		}
	}
	return Plugin_Handled;
}

//emergency button stuffz
public void DrawEmergencyPanel(client)
{
	Menu panel = new Menu(EmergencyHandler1);
	char call[MAX_NAME_LENGTH] = "";
	if(emergencyUses[client] >= 1)
		Format(call,sizeof(call),"Call emergency meeting (%d remaining)",emergencyUses[client]);
	else
		Format(call,sizeof(call),"Can't call an emergency meeting! (%d remaining)",emergencyUses[client]);
	panel.SetTitle("Emergency Button");
	panel.AddItem("0", call);
	panel.ExitButton = true;
	if(IsValidClient(client))
	{
		panel.Display(client,60);
	}
}

public int EmergencyHandler1 (Menu menu, MenuAction action, int client, int param2)
{
	char info[MAX_NAME_LENGTH];
	menu.GetItem(param2, info, sizeof(info));
	if (action == MenuAction_Select && playerState[client] != State_Ghost && playerState[client] != State_ImpostorGhost && ventState[client] != VentState_InsideVent && emergencyButton[client] == Emergency_NextToButton)
	{
		SetVariantString("push");
		if(IsValidEntity(mapEmergencyButtonId))
			AcceptEntityInput(mapEmergencyButtonId,"SetAnimation");
		StartMeeting(client, Reason_EmergencyButton, 0);
		emergencyUses[client]--;
		return 1;
	}
	return 0;
}

//make sure the round doesn't linger when people leave
public Action Event_PlayerDisconnect(Handle:event, String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	persistentUITimer[client] = null;
	if(IsValidClient)
	{
		if(TF2_GetClientTeam(client) == TFTeam_Spectator)
			return Plugin_Continue;
		if(playerState[client] == State_Impostor)
			activeImpostors--;
		if(activeImpostors == 0) //player was last impostor
			RoundWon(State_Crewmate);
		else if(GetNonGhostTeamCount(TFTeam_Red)-1 <= 2)
			RoundWon(State_Impostor);
	}

	return Plugin_Handled;
}

//chat when appropriate
public Action Listener_Chat(client, const String:command[], argc)
{
	if(startOfRound != RoundStart_Ongoing)
		return Plugin_Continue;
	if(g_votingState == VotingState_NoVote || g_votingState == VotingState_Ejection)
		return Plugin_Handled;

	char speech[MAX_MESSAGE_LENGTH];
	int start = 0;

	GetCmdArgString(speech,sizeof(speech));
	if (speech[0] == '"')
	{
		start = 1;
		int length = strlen(speech);
		if (speech[length-1] == '"')
			speech[length-1] = '\0';
	}

	char newSpeech[MAX_MESSAGE_LENGTH];
	strcopy(newSpeech, sizeof(speech), speech[start]);

	for(new i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i))
		{
			char chatColor[MAX_NAME_LENGTH];
			SkinSwitch(i, Skin_ChatColor, chatColor);
			switch(playerState[client])
			{
				case State_Crewmate:
				{
					CPrintToChatEx(i, client, "%s%N{default} :  %s", chatColor, client, newSpeech);
				}
				case State_Impostor:
				{
					if(playerState[i] == State_Impostor)
						CPrintToChatEx(i, client, "{default}%t %s%N{default} :  %s", "impostor_prefix", chatColor, client, newSpeech);
					else
						CPrintToChatEx(i, client, "%s%N{default} :  %s", chatColor, client, newSpeech);
				}
				case State_Ghost:
				{
					if(playerState[i] == State_Ghost || playerState[i] == State_ImpostorGhost)
						CPrintToChatEx(i, client, "{default}%t %s%N{default} :  %s", "ghost_prefix", chatColor, client, newSpeech);
				}
				case State_ImpostorGhost:
				{
					if(playerState[i] == State_Ghost)
						CPrintToChatEx(i, client, "{default}%t %s%N{default} :  %s", "ghost_prefix", chatColor, client, newSpeech);
					else if(playerState[i] == State_ImpostorGhost)
						CPrintToChatEx(i, client, "{default}%t %t %s%N{default} :  %s", "ghost_prefix", "impostor_prefix", chatColor, client, newSpeech);
				}
			}
		}
	}

	return Plugin_Handled;
}

stock int GetTFTeamCount(TFTeam tfteam)
{
	int numbert = 0;
	for (new i=1; i<=MaxClients; i++)
	{
		if(IsValidClient(i))
		{
			if (TF2_GetClientTeam(i) == tfteam) 
				numbert++;
		}
	}
	return numbert;
} 

//set player to spy upon spawn
public Action OnPlayerSpawn(Handle hEvent, char[] strEventName, bool bDontBroadcast)
{
	int Client = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	char iSkinName[MAX_NAME_LENGTH];
	if (!IsValidClient(Client)) return Plugin_Handled;
	if(GetClientCount(true) >= requiredToStart.IntValue && startOfRound == RoundStart_Ended)
		startOfRound = RoundStart_Starting;
	if(startOfRound == RoundStart_Starting || GetTFTeamCount(TFTeam_Red) <= requiredToStart.IntValue || g_knifeCount[Client] == -3)
	{
		TF2_RegeneratePlayer(Client);
		g_knifeCount[Client] = -3; //crewmates shouldn't have a knife count
		SetClientListeningFlags(Client, VOICE_MUTED);
		TF2_ChangeClientTeam(Client,TFTeam_Red);
		TF2_SetPlayerClass(Client, TFClass_Spy, false, true);
		TF2_RemoveWeaponSlot(Client,0); //revolver
		TF2_RemoveWeaponSlot(Client,3); //disguise kit?
		TF2_RemoveWeaponSlot(Client,4); //why are
		TF2_RemoveWeaponSlot(Client,5); //there seven
		TF2_RemoveWeaponSlot(Client,6); //weapon slots
		EmitSoundToClient(Client, SPAWN_SOUND);
		voteStorage[Client] = 0;
		emergencyUses[Client] = emergencyButtonMaxUses.IntValue;
		ventState[Client] = VentState_Crewmate;
		playerState[Client] = State_Crewmate;
		SDKUnhook(Client, SDKHook_OnTakeDamage, OnTakeDamage);
		SDKUnhook(Client,SDKHook_SetTransmit,Hook_SetTransmitVent);
		SDKUnhook(Client,SDKHook_SetTransmit,Hook_SetTransmit);
		SetVariantString(SPY_MODEL); //let's get our custom model in
		AcceptEntityInput(Client, "SetCustomModel"); //yeah set it in place :)
		SetEntProp(Client, Prop_Send, "m_bUseClassAnimations", 1); //enable animations otherwise you will be threatened by the living dead
		SetEntProp(Client, Prop_Send, "m_bForcedSkin", 1); //enable changing the skin
		SetEntProp(Client, Prop_Send, "m_nForcedSkin", iSkin); //set the skin
		SkinSwitch(iSkin, Skin_NameWithSkin, iSkinName);
		PrintCenterText(Client,"%t (%s)","state_crewmate",iSkinName);
		SetEntityRenderMode(Client, RENDER_TRANSCOLOR); //allow for transparency
		SetEntityRenderColor(Client, 255, 255, 255, 255); //set as opaque for now, maybe not a good idea this early but meh
		g_playerSkin[Client] = iSkin;
		int seq = g_aSpawnPoints.Get(iSkin);
		if(seq > MaxClients && IsValidEntity(seq))
		{
			float seqOrigin[3];
			float seqAngles[3];
			GetEntPropVector(seq, Prop_Send, "m_vecOrigin", seqOrigin);
			GetEntPropVector(seq, Prop_Send, "m_angRotation", seqAngles);
			TeleportEntity(Client,seqOrigin,seqAngles,NULL_VECTOR); //let's teleport the player to a sequential spawn point
		}
		if(iSkin < 11)
			iSkin++;
		else
			iSkin = 0; //we don't want all subsequent colors to be default (red?) if there are more than 32 players, so reset the counter
		SDKHook(Client, SDKHook_OnTakeDamage, OnTakeDamage);
		if(persistentUITimer[Client] != INVALID_HANDLE)
		{
			KillTimer(persistentUITimer[Client],false); //kill or suffer the pain of eventual near-instant timers
		}
		persistentUITimer[Client] = CreateTimer(1.0, UITimer, GetClientUserId(Client), TIMER_REPEAT); //this should be the one and only UI timer for the client, for now
	}
	else if(startOfRound == RoundStart_NotEnoughPlayers && GetClientCount(true) >= requiredToStart.IntValue)
		RoundWon(State_Ghost);
	else
	{
		TF2_ChangeClientTeam(Client,TFTeam_Spectator);
		PrintToChat(Client,"%t","ongoing");
	}
	return Plugin_Handled;
}

public int VoteHandler1 (Menu menu, MenuAction action, int param1, int param2)
{
	char info[MAX_NAME_LENGTH];
	menu.GetItem(param2, info, sizeof(info));
	if (action == MenuAction_Select)
	{
		if(alreadyVoted[param1] != 1 && g_votingState == VotingState_Voting)
		{
			int votedFor = GetClientOfUserId(votePlayerCorelation[StringToInt(info)]);
			char chatColor[MAX_NAME_LENGTH];
			char nameOfParam1[MAX_NAME_LENGTH];
			char nameOfVotedFor[MAX_NAME_LENGTH];
			SkinSwitch(param1, Skin_ChatColor, chatColor);
			Format(nameOfParam1, MAX_NAME_LENGTH, "%s%N", chatColor, param1);
			if(votedFor > 0)
			{
				voteStorage[votedFor] += 1;
				char chatColor2[MAX_NAME_LENGTH];
				SkinSwitch(votedFor, Skin_ChatColor, chatColor2);
				Format(nameOfVotedFor, MAX_NAME_LENGTH, "%s%N", chatColor2, votedFor);
				CPrintToChatAll("{default}* %t","voted",nameOfParam1,nameOfVotedFor);
			}
			else //assume you voted skip, might break listen servers
			{
				voteStorage[MAXPLAYERS+1] += 1;
				CPrintToChatAll("{default}* %t","skipped",nameOfParam1);
			}
			alreadyVoted[param1] = 1;
			return 1;
		}
	}
	return 0;
}

public void DrawVotingPanels(client)
{
	Menu panel = new Menu(VoteHandler1);
	panel.SetTitle("Vote for ejection!");
	panel.AddItem("0", "Skip");
	votePlayerCorelation[0] = 0;
	for(new i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i) && playerState[i] != State_Ghost)
		{
			votePlayerCorelation[i+1] = GetClientUserId(i);
			char name[MAX_NAME_LENGTH];
			char itemnum[255];
			IntToString(i+1,itemnum,32); //this is causing some votes to count as "skipped" when they aren't?
			char nameOfBody[MAX_NAME_LENGTH];
			SkinSwitch(i, Skin_Name, nameOfBody);
			if((playerState[i] == State_Impostor && playerState[client] == State_Impostor) || (playerState[i] == State_ImpostorGhost && playerState[client] == State_ImpostorGhost))
				Format(name,MAX_NAME_LENGTH,"%N (%s) %t", i, nameOfBody, "impostor_votingdiscriminator");
			else
				Format(name,MAX_NAME_LENGTH,"%N (%s)", i, nameOfBody);
			if(playerState[i] == State_Ghost || playerState[i] == State_ImpostorGhost)
				panel.AddItem(itemnum, name, ITEMDRAW_DISABLED);
			else
				panel.AddItem(itemnum, name);
		}
	}
	panel.ExitButton = false;
	if(IsValidClient(client) && playerState[client] != State_Ghost)
	{
		panel.Display(client, votingCount.IntValue);
	}
}

public void StartMeeting(int announcer, Reason reason, int skinOfBody)
{
	SetConVarBool(voiceEnable,true);
	currentMeeting = reason;
	if(g_votingState != VotingState_NoVote)
		return;
	if(reason == Reason_NoMeeting)
		return;
	iSkin = 0;
	char nameOfBody[MAX_NAME_LENGTH];
	SkinSwitch(skinOfBody, Skin_NameWithSkin, nameOfBody);
	Format(voteAnnouncer,MAX_NAME_LENGTH,"%N",announcer);
	for(new Client = 1; Client <= MaxClients; Client++)
	{
		if(IsValidClient(Client) && TF2_GetClientTeam(Client) == TFTeam_Red)
		{
			g_knifeCount[Client] = -1;
			int seq = g_aSpawnPoints.Get(iSkin);
			if(seq > MaxClients && IsValidEntity(seq))
			{
				float seqOrigin[3];
				float seqAngles[3];
				GetEntPropVector(seq, Prop_Send, "m_vecOrigin", seqOrigin);
				GetEntPropVector(seq, Prop_Send, "m_angRotation", seqAngles);
				TeleportEntity(Client,seqOrigin,seqAngles,NULL_VECTOR); //let's teleport the player to a sequential spawn point
			}
			switch(reason)
			{
				case Reason_FoundBody:
				{
					PrintCenterText(Client,"%t","reason_foundbody",voteAnnouncer,nameOfBody);
					EmitSoundToClient(Client,FOUNDBODY_SOUND);
				}
				case Reason_EmergencyButton:
				{
					PrintCenterText(Client,"%t","reason_emergencybutton",voteAnnouncer);
					EmitSoundToClient(Client,EMERGENCY_SOUND);
				}
			}
			if(iSkin < 11)
				iSkin++;
			else
				iSkin = 0; //reset counter
			voteCounter[Client] = preVotingCount.IntValue;
			SetEntityMoveType(Client, MOVETYPE_NONE);
		}
	}
	PrintToChatAll("%t","unmuted");
	g_votingState = VotingState_PreVoting;
	CreateTimer(preVotingCount.FloatValue, VoteTimer);
}

public Action VoteTimer(Handle timer)
{
	switch(g_votingState)
	{
		case VotingState_PreVoting:
		{
			g_votingState = VotingState_Voting;
			for(new i = 1; i <= MaxClients; i++)
			{
				if(IsValidClient(i))
				{
					DrawVotingPanels(i);
					SetEntityMoveType(i, MOVETYPE_NONE);
					voteCounter[i] = votingCount.IntValue;
					SetClientListeningFlags(i, VOICE_NORMAL);
				}
			}
			CreateTimer(votingCount.FloatValue, VoteTimer); //can we do recursive?
		}
		case VotingState_Voting:
		{
			g_votingState = VotingState_Ejection;
			OrderArray();
			if(voteStorage[firstVote] == voteStorage[secondVote])
				currentMeeting = Reason_Tie;
			else if(firstVote == MAXPLAYERS+1)
				currentMeeting = Reason_Skip;
			else if(!IsValidClient(firstVote))
				currentMeeting = Reason_Disconnected;
			else
			{
				switch(playerState[firstVote])
				{
					case State_Crewmate:
					{
						playerState[firstVote] = State_Ghost;
						currentMeeting = (anonymousEjection.BoolValue ? Reason_Anonymous : Reason_Crewmate);
					}
					case State_Impostor:
					{
						activeImpostors--;
						playerState[firstVote] = State_ImpostorGhost;
						currentMeeting = (anonymousEjection.BoolValue ? Reason_Anonymous : Reason_Impostor);
					}
				}
				ApplyGhostEffect(firstVote, GhostReason_Ejected);
			}
			for(new i = 1; i <= MaxClients; i++)
			{
				if(IsValidClient(i))
				{
					SetEntityMoveType(i, MOVETYPE_NONE);
					voteCounter[i] = ejectionCount.IntValue;
					alreadyVoted[i] = 0;
					voteStorage[i] = 0;
					SetClientListeningFlags(i, VOICE_MUTED);
				}
			}
			PrintToChatAll("%t","shh");
			voteStorage[MAXPLAYERS+1] = 0; //clear skip votes
			SetConVarBool(voiceEnable,false);
			CreateTimer(ejectionCount.FloatValue, VoteTimer); //I don't feel so good...
		}
		case VotingState_Ejection:
		{
			currentMeeting = Reason_NoMeeting;
			g_votingState = VotingState_NoVote;
			for(new i = 1; i <= MaxClients; i++)
			{
				if(IsValidClient(i))
				{
					switch(playerState[i])
					{
						case State_Impostor:
						{
							g_knifeCount[i] = knifeConVarCount.IntValue;
							SetEntityMoveType(i, MOVETYPE_WALK);
						}
						case State_Ghost:
							SetEntityMoveType(i, MOVETYPE_NOCLIP);
						case State_ImpostorGhost:
							SetEntityMoveType(i, MOVETYPE_NOCLIP);
						default:
							SetEntityMoveType(i, MOVETYPE_WALK);
					}
					voteCounter[i] = 0;
				}
			}
			if(GetNonGhostTeamCount(TFTeam_Red)-activeImpostors <= 1)
				RoundWon(State_Impostor);
			else if(activeImpostors == 0)
				RoundWon(State_Crewmate);
		}
	}

}

public Action GameStart(Handle event, char[] name, bool:Broadcast) {
	startOfRound = RoundStart_Starting;
	g_hWeaponEquip = EndPrepSDKCall();
	if (!g_hWeaponEquip)
	{
		SetFailState("Failed to prepare the SDKCall for giving weapons. Try updating gamedata or restarting your server.");
	}
	activeImpostors = impostorCount.IntValue; //set the value initially
	firstVote = 0;
	secondVote = 0;
	currentMeeting = Reason_NoMeeting;
	g_votingState = VotingState_NoVote;
	voteStorage[MAXPLAYERS+1] = 0; //clear skip votes
	//find out who is the impostor if there are enough players
	//this is bad code
	if(GetClientCount(true) >= requiredToStart.IntValue)
	{
		char iSkinName[MAX_NAME_LENGTH];
		for(new Client = 1; Client <= MaxClients; Client++)
		{
			if(IsValidClient(Client))
			{
				TF2_ChangeClientTeam(Client,TFTeam_Red);
				TF2_RespawnPlayer(Client);
			}
		}
		for(new Impostor = 1; Impostor <= impostorCount.IntValue; Impostor++)
		{
			int randomClient = -1;
			do
			{
				randomClient = GetRandomInt(1, MaxClients); //absolutely sucks
			}
			while(!IsClientInGame(randomClient) || TF2_GetClientTeam(randomClient) != TFTeam_Red || playerState[randomClient] == State_Impostor);
			SkinSwitch(randomClient, Skin_Name, iSkinName);
			ventState[randomClient] = VentState_NoVent;
			playerState[randomClient] = State_Impostor;
			PrintCenterText(randomClient,"%t (%s)","state_impostor",iSkinName);
			int glow = TF2_AttachBasicGlow(randomClient, TFTeam_Red); //impostors get a nice glow effect
			SetEntityRenderColor(glow, 255, 0, 0, 0);
			SDKHook(glow,SDKHook_SetTransmit,Hook_SetTransmitImpostor);
			SDKHook(randomClient,SDKHook_SetTransmit,Hook_SetTransmitVent);
		}
		CreateTimer(5.0,TransitionToRoundStart);
	}
	else
	{
		startOfRound = RoundStart_NotEnoughPlayers;
		PrintCenterTextAll("%t","notenoughplayers",impostorCount.IntValue,GetClientCount(true),requiredToStart.IntValue);
	}
}

public Action TransitionToRoundStart(Handle timer, int userid)
{
	PrintToChatAll("%t","shh");
	for(new client = 1; client <= MaxClients; client++)
	{
		if(IsValidClient(client))
		{
			SetClientListeningFlags(client, VOICE_MUTED);
			switch(playerState[client])
			{
				case State_Impostor:
					g_knifeCount[client] = knifeConVarCount.IntValue;
				default:
					g_knifeCount[client] = -1;
			}
		}
	}
	startOfRound = RoundStart_Ongoing;
}

stock bool IsValidClient(int iClient, bool bAlive = false)
{
	if (iClient >= 1 &&
		iClient <= MaxClients &&
		IsClientConnected(iClient) &&
		IsClientInGame(iClient) &&
		(bAlive == false || IsPlayerAlive(iClient)))
	{
		return true;
	}

	return false;
}

public Action Listener_Death(client, const String:command[], argc)
{
	return Plugin_Handled; //when the player uses 'kill' or 'explode' we don't want to do anything
}

public Action UITimer(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	// https://forums.alliedmods.net/showpost.php?p=862230&postcount=6
	int stateOffset = FindSendPropInfo("CTeamplayRoundBasedRulesProxy", "m_iRoundState");
	if (!IsValidClient(client) || g_votingState == VotingState_EndOfRound || stateOffset == 6 || stateOffset == 8 || (g_knifeCount[client] == -3 && g_votingState == VotingState_EndOfRound))
	{
		persistentUITimer[client] = null;
		return Plugin_Stop;
	}
	if (g_knifeCount[client] == 0) //the only way to have a knifecount > -1 is if you killed someone (>^-^)>
	{
		EmitSoundToClient(client, RECHARGE_SOUND);
		g_knifeCount[client] = -2; //go to -2 so we don't decrement anymore
	}
	else if (g_knifeCount[client] > 0)
		g_knifeCount[client]--;
	if(voteCounter[client] > 0)
		voteCounter[client]--;
	switch (g_votingState)
	{
		case VotingState_PreVoting:
		{
			SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
			ShowSyncHudText(client, g_hHud, "%t\n%t\n%t","votingstate_prevoting","startedvote",voteAnnouncer,"untilvotingstarts",voteCounter[client]);
		}
		case VotingState_Voting:
		{
			SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
			ShowSyncHudText(client, g_hHud, "%t\n%t\n%t","votingstate_voting","startedvote",voteAnnouncer,"untilvotingends",voteCounter[client]);
		}
		case VotingState_Ejection:
		{
			SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
			char nameOfFirstVote[MAX_NAME_LENGTH];
			if(IsValidClient(firstVote))
				Format(nameOfFirstVote,MAX_NAME_LENGTH,"%N",firstVote);
			switch(currentMeeting)
			{
				case Reason_Anonymous:
					ShowSyncHudText(client, g_hHud, "%t\n%t","reason_anonymous",nameOfFirstVote,"untilejectionends",voteCounter[client]);
				case Reason_Crewmate:
					ShowSyncHudText(client, g_hHud, "%t\n%t\n%t","reason_crewmate",nameOfFirstVote,"impostorsremain",activeImpostors,"untilejectionends",voteCounter[client]);
				case Reason_Impostor:
					ShowSyncHudText(client, g_hHud, "%t\n%t\n%t","reason_impostor",nameOfFirstVote,"impostorsremain",activeImpostors,"untilejectionends",voteCounter[client]);
				case Reason_Tie:
					ShowSyncHudText(client, g_hHud, "%t\n%t","reason_tie","untilejectionends",voteCounter[client]);
				case Reason_Skip:
					ShowSyncHudText(client, g_hHud, "%t\n%t","reason_skip","untilejectionends",voteCounter[client]);
				case Reason_Disconnected:
					ShowSyncHudText(client, g_hHud, "%t\n%t","reason_disconnected","untilejectionends",voteCounter[client]);
				default:
					ShowSyncHudText(client, g_hHud, "%t","untilejectionends",voteCounter[client]);
			}
		}
		default:
		{
			int entity = GetClientAimTarget(client, false);
			char targetname[128];
			char classname[MAX_NAME_LENGTH];
			char reportBody[MAX_NAME_LENGTH] = "";
			char emergency[MAX_NAME_LENGTH] = "";
			if (IsValidEntity(entity))
			{
				GetEntPropString(entity, Prop_Data, "m_iClassname", classname, sizeof(classname));
				if(StrEqual(classname,"prop_dynamic"))
				{
					GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
					if(StrEqual(targetname,"deadbody",true))
						Format(reportBody,sizeof(reportBody),"%t\n","reportbody");
					else
						Format(reportBody,sizeof(reportBody),"");
				}
			}
			switch(emergencyButton[client])
			{
				case Emergency_NextToButton:
					Format(emergency,sizeof(emergency),"%t\n","emergencybutton");
				default:
					Format(emergency,sizeof(emergency),"");
			}
			switch(playerState[client])
			{
				case (State_Crewmate):
				{
					SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
					ShowSyncHudText(client, g_hHud, "%s%s%t",emergency,reportBody,"tasks");
				}
				case (State_Impostor):
				{
					SetHudTextParams(0.15, 0.15, 3.0, 255, 0, 0, 255, 1, 6.0, 0.1, 0.1);
					char ventHere[MAX_NAME_LENGTH] = "";
					switch(ventState[client])
					{
						case VentState_InsideVent:
						{
							DrawVentPanels(client);
							Format(ventHere,sizeof(ventHere),"%t\n","ventstate_insidevent");
						}
						case VentState_OnTopOfVent:
							Format(ventHere,sizeof(ventHere),"%t\n","ventstate_ontopofvent");
						default:
							Format(ventHere,sizeof(ventHere),"");
					}
					if (g_knifeCount[client] > 1 || g_knifeCount[client] == 0)
						ShowSyncHudText(client, g_hHud, "%s%s%s%t\n%t\n%t",emergency,reportBody,ventHere,"knifedelayplural",g_knifeCount[client],"impostor_description","faketasks");
					else if (g_knifeCount[client] >= 0)
						ShowSyncHudText(client, g_hHud, "%s%s%s%t\n%t\n%t",emergency,reportBody,ventHere,"knifedelay",g_knifeCount[client],"impostor_description","faketasks");
					else
						ShowSyncHudText(client, g_hHud, "%s%s%s%t\n%t",emergency,reportBody,ventHere,"impostor_description","faketasks");
				}
				case (State_ImpostorGhost):
				{
					SetHudTextParams(0.15, 0.15, 3.0, 255, 0, 0, 255, 1, 6.0, 0.1, 0.1);
					ShowSyncHudText(client, g_hHud, "%t\n%t","dead","impostorghost_description");
				}
				default:
				{
					SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
					ShowSyncHudText(client, g_hHud, "%t\n%t\n%t","dead","ghost_description","tasks");
				}
			}
		}
	}
	
	return Plugin_Continue;
}

//impostor has hurt someone! (friendly fire must be on)
public Action OnTakeDamage(client, &attacker, &inflictor, &Float:damage, &damagetype)
{
	if(playerState[client] == State_Impostor || g_votingState != VotingState_NoVote)
		return Plugin_Handled;
	if(IsValidClient(attacker))
	{
		if(playerState[attacker] != State_Impostor || g_knifeCount[attacker] > -2 || ventState[attacker] == VentState_InsideVent)
			return Plugin_Handled;
	}
	new Float:vOrigin[3];
	float seqAngles[3];
	if(playerState[client] == State_Crewmate)
	{
		new ent = CreateEntityByName("prop_dynamic_override"); //spawning a prop that is just the spy laying down
		DispatchKeyValue(ent, "targetname", "deadbody");
		GetClientAbsOrigin(client, vOrigin);
		GetEntPropVector(client, Prop_Send, "m_angRotation", seqAngles);
		if (ent > MaxClients && IsValidEntity(ent))
		{
			char[] newStringSkin = "0";
			SetEntProp(ent, Prop_Send, "m_nSolidType", 6); //SOLID_VPHYSICS
			DispatchKeyValue(ent, "model", SPY_MODEL);
			IntToString(g_playerSkin[client],newStringSkin,255);
			DispatchKeyValue(ent, "skin", newStringSkin);
			TeleportEntity(ent, vOrigin, seqAngles, NULL_VECTOR);
			new Float:vNewOrigin[3];
			vNewOrigin = vOrigin;
			vNewOrigin[2] += 20.0; //if the attacker spawns too low to the ground, they will be stuck inside of the dead body
			TeleportEntity(attacker, vNewOrigin, NULL_VECTOR, NULL_VECTOR);
			DispatchSpawn(ent);
		}
		playerState[client] = State_Ghost;
		if(IsValidClient(attacker))
		{
			EmitSoundToClient(attacker, KILL_SOUND);
			g_knifeCount[attacker] = knifeConVarCount.IntValue;
			ApplyGhostEffect(client, GhostReason_Killed);
		}
		else
			ApplyGhostEffect(client, GhostReason_Suicide);
		if(GetNonGhostTeamCount(TFTeam_Red)-activeImpostors <= 1)
			RoundWon(State_Impostor);
	}
	return Plugin_Handled;
}

public Action Hook_SetTransmitImpostor(entity, client)
{
	int ent = GetEntPropEnt(entity, Prop_Data, "m_hEffectEntity");
	if(TF2_GetClientTeam(client) == TFTeam_Spectator)
		return Plugin_Continue;
	switch(playerState[client])
	{
		case State_Impostor:
			if(playerState[ent] == State_Impostor)
				return Plugin_Continue;
		case State_ImpostorGhost:
			if(playerState[ent] == State_Impostor || playerState[ent] == State_ImpostorGhost)
				return Plugin_Continue;
	}
	return Plugin_Handled;
}

public Action Hook_SetTransmitVent(entity, client)
{
	if (ventState[entity] != VentState_InsideVent || entity == client)
		return Plugin_Continue;
	return Plugin_Handled;
}

public Action Hook_SetTransmit(entity, client)
{
	if (TF2_GetClientTeam(client) == TFTeam_Spectator || entity == client || playerState[client] == State_Ghost || playerState[client] == State_ImpostorGhost)
		return Plugin_Continue;
	return Plugin_Handled;
}

public void RoundWon(PlayerState winners)
{
	startOfRound = RoundStart_Ended;
	g_votingState = VotingState_EndOfRound;
	new iEnt = -1;
	iEnt = FindEntityByClassname(iEnt, "game_round_win");
	
	if (!IsValidEntity(iEnt))
	{
		iEnt = CreateEntityByName("game_round_win");
		DispatchSpawn(iEnt);
	}
	switch(winners)
	{
		case (State_Crewmate):
		{
			SetVariantInt(2);
			PrintCenterTextAll("%t","crewmates_win");
		}
		case (State_Impostor):
		{
			SetVariantInt(3);
			PrintCenterTextAll("%t","impostors_win");
		}
		default:
		{
			SetConVarInt(restartGame,5);
			PrintCenterTextAll("%t","default_win");
			return;
		}
	}
	for(new Client = 1; Client <= MaxClients; Client++)
	{
		if(IsValidClient(Client) && TF2_GetClientTeam(Client) == TFTeam_Red)
		{
			g_knifeCount[Client] = -3;
		}
	}
	DispatchKeyValue(iEnt,"force_map_reset","1");
	AcceptEntityInput(iEnt, "SetTeam");
	AcceptEntityInput(iEnt, "RoundWin");
}

stock int GetNonGhostTeamCount(TFTeam team)
{
	int number = 0;
	for (new i=1; i<=MaxClients; i++)
	{
		if(IsValidClient(i))
		{
			if (playerState[i] != State_Ghost && playerState[i] != State_ImpostorGhost && TF2_GetClientTeam(i) == team) 
				number++;
		}
	}
	return number;
} 

//for debugging purposes
public Action Command_Restart(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_amongus_restart <crewmates|impostors|nobody>");
		return Plugin_Handled;
	}

	char arg[65];
	GetCmdArg(1, arg, sizeof(arg));

	if(StrEqual(arg,"crewmates"))
		RoundWon(State_Crewmate);
	else if(StrEqual(arg, "impostors"))
		RoundWon(State_Impostor);
	else if(StrEqual(arg,"nobody"))
		RoundWon(State_Ghost);
	else
	{
		ReplyToCommand(client, "[SM] Usage: sm_amongus_restart <crewmates|impostors|nobody>");
		return Plugin_Handled;
	}
	return Plugin_Handled;
}

public Action Command_BecomeImpostor(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_amongus_becomeimpostor <#userid|name>");
		return Plugin_Handled;
	}

	char arg[65];
	GetCmdArg(1, arg, sizeof(arg));
	
	char target_name[MAX_TARGET_LENGTH];
	int target_list[MAXPLAYERS], target_count;
	bool tn_is_ml;
	
	if ((target_count = ProcessTargetString(
			arg,
			client,
			target_list,
			MAXPLAYERS,
			COMMAND_FILTER_ALIVE,
			target_name,
			sizeof(target_name),
			tn_is_ml)) <= 0)
	{
		return Plugin_Handled;
	}
	activeImpostors++;
	for (int i = 0; i < target_count; i++)
	{
		LogAction(client, target_list[i], "\"%L\" set \"%L\" as an impostor!", client, target_list[i]);
		ventState[target_list[i]] = VentState_NoVent;
		playerState[target_list[i]] = State_Impostor;
		g_knifeCount[target_list[i]] = 0;
	}
	
	return Plugin_Handled;
}

public Action TF2Items_OnGiveNamedItem(client, String:classname[], iItemDefinitionIndex, &Handle:hItem)
{
	if (StrEqual(classname, "tf_wearable"))
	{
		return Plugin_Handled; //we don't wan't cosmetics due to the colors of the players
	}
	return Plugin_Continue; 
}
// https://forums.alliedmods.net/showthread.php?t=187237
public void OrderArray()
{
	// Create player list
	new list_players[MAXPLAYERS+2]; //+2 because skip
	int list_players_size;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i))
		{
			list_players[list_players_size] = i;    // Store player index
			list_players_size++;
		}
	}

	list_players[MAXPLAYERS+1] = MAXPLAYERS+1;

	SortCustom1D(list_players, sizeof(list_players), sortfunc);

	// Output
	firstVote = list_players[0];
	secondVote = list_players[1];
} 

public sortfunc(elem1, elem2, const array[], Handle:hndl)
{
	if(voteStorage[elem1] > voteStorage[elem2])
	{
		return -1;
	}
	else if(voteStorage[elem1] < voteStorage[elem2])
	{
		return 1;
	}
	return 0;
}

public void SkinSwitchC(int client)
{
	SkinSwitch(client, Skin_RenderColor, "");
}

public void SkinSwitch(int client, SkinSwitchType basetype, char[] chatColor)
{
	SkinSwitchType type;
	int skin;
	if(basetype == Skin_NameWithSkin)
	{
		skin = client;
		type = Skin_Name;
	}
	else
	{
		if(!IsValidClient(client))
			return;
		skin = g_playerSkin[client];
		type = basetype;
	}
	switch(skin)
	{
		case 0:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{red}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_red");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 255, 128, 128, 128);
			}
			
		}
		case 1:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{blue}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_blue");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 128, 128, 255, 128);
			}
			
		}
		case 2:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{darkgrey}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_black");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 128, 128, 128, 128);
			}
			
		}
		case 3:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{brown}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_brown");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 210, 180, 140, 128);
			}
			
		}
		case 4:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{cyan}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_cyan");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 0, 255, 255, 128);
			}
			
		}
		case 5:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{darkgreen}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_green");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 0, 128, 0, 128);
			}
			
		}
		case 6:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{lime}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_lime");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 0, 255, 0, 128);
			}
		}
		case 7:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{orange}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_orange");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 255, 165, 0, 128);
			}
		}
		case 8:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{hotpink}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_pink");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 255, 105, 180, 128);
			}
		}
		case 9:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{purple}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_purple");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 255, 105, 180, 128);
			}
		}
		case 10:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{white}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_white");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 255, 255, 255, 128);
			}
		}
		case 11:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{yellow}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_yellow");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 255, 255, 0, 128);
			}
		}
		default:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{default}");
				case Skin_Name:
					Format(chatColor, MAX_NAME_LENGTH, "%t", "color_default");
				case Skin_RenderColor:
					SetEntityRenderColor(client, 255, 255, 255, 128);
			}
		}
	}
}

public void ApplyGhostEffect(int client, GhostReason reason)
{
	switch(reason)
	{
		case GhostReason_Killed:
			PrintCenterText(client,"%t","ghostreason_killed");
		case GhostReason_Suicide:
			PrintCenterText(client,"%t","ghostreason_suicide");
		case GhostReason_Ejected:
			PrintCenterText(client,"%t","ghostreason_ejected");
		default:
			PrintCenterText(client,"%t","ghostreason_generic");
	}
	SDKHook(client,SDKHook_SetTransmit,Hook_SetTransmit);
	SetEntityMoveType(client, MOVETYPE_NOCLIP);
	SkinSwitchC(client);
}

/*
　　ﾟ　　　　　　. ,　　　　.　 
　　　.　　　 　　.　　　　　　　 　.
.　　 。　　　　　 ඞ 。 . 　　 • 　　　　•
　　ﾟ　　　.　　　. 　　　　.　 .
　　　.　　 　　.  　　.　　。　　 。　.
*/
