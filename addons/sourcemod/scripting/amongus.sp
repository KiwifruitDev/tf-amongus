//Original concept by u/IceboundCat6, brought to life by u/MouseDroidPoW

#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <morecolors>
#include <sdkhooks>
#include <tf2items>
#include <tf2items_giveweapon>
#include <stocksoup/entity_prefabs>

#undef REQUIRE_EXTENSIONS
#include <steamtools>

#pragma semicolon 1
#pragma newdecls optional

#define SPY_MODEL "models/amongus/player/spy.mdl"
#define RECHARGE_SOUND "player/recharged.wav"
#define FOUNDBODY_SOUND "amongus/foundbody.mp3"
#define EMERGENCY_SOUND "amongus/emergencymeeting.mp3"
#define KILL_SOUND "amongus/kill.mp3"
#define SPAWN_SOUND "amongus/spawn.mp3"

#define PLUGIN_VERSION "0.1.3"

public Plugin myinfo =
{
	name = "[TF2] Among Us",
	author = "IceboundCat6 & TeamPopplio",
	description = "Among Us in TF2!",
	version = PLUGIN_VERSION,
	url = "https://github.com/TeamPopplio/tf-amongus"
};

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
	Skin_RenderColor //sets the client's render color to their respective color
};

enum GhostReason
{
	GhostReason_Killed = 0, //the player has been killed
	GhostReason_Suicide, //the player has died without an attacker
	GhostReason_Ejected, //the player has suffocated from being ejected into outer space
	GhostReason_Generic //the player has been killed but the map is not tfau_theskeld
};


//I swear [MAXPLAYERS +1] is gonna come back and haunt me someday

Reason currentMeeting = Reason_NoMeeting; //currently unused
PlayerState playerState[MAXPLAYERS +1];
VotingState g_votingState;
char voteAnnouncer[MAX_NAME_LENGTH];
int g_knifeCount[MAXPLAYERS +1];
int g_playerSkin[MAXPLAYERS +1];
int activeImpostors = 0;
int voteCounter[MAXPLAYERS +1];
int alreadyVoted[MAXPLAYERS +1]; //0 or 1 please
int votePlayerCorelation[MAXPLAYERS +1]; //reverse: key = vote id, value = user id
int voteStorage[MAXPLAYERS +2]; //plus 1 extra because last slot will be used for skip
int firstVote; //used for ejection
int secondVote; //used to test for a tie
Handle g_hHud;
Handle persistentUITimer[MAXPLAYERS +1];
Handle g_hWeaponEquip;
ConVar knifeConVarCount;
ConVar impostorCount;
ConVar preVotingCount;
ConVar votingCount;
ConVar ejectionCount;
ConVar anonymousEjection;
ArrayList g_aSpawnPoints;

public OnMapStart()
{
	PrecacheModel(SPY_MODEL, true);
	PrecacheSound(RECHARGE_SOUND, true);
	PrecacheSound(FOUNDBODY_SOUND, true);
	PrecacheSound(EMERGENCY_SOUND, true);
	PrecacheSound(KILL_SOUND, true);
	PrecacheSound(SPAWN_SOUND, true);
}

public void OnPluginStart()
{
	char gameDesc[64];
	Format(gameDesc, sizeof(gameDesc), "Among Us (%s)", PLUGIN_VERSION);
	Steam_SetGameDescription(gameDesc);
	HookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Post);
	HookEvent("teamplay_round_start", GameStart);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
	impostorCount = CreateConVar("sm_amongus_impostorcount", "1", "Sets the amount of impostors that can be applied in a single game.");
	knifeConVarCount = CreateConVar("sm_amongus_knifecount", "20", "Sets how many seconds an impostor should wait before being able to use their knife.");
	preVotingCount = CreateConVar("sm_amongus_prevotingtimer", "30", "Sets how many seconds a vote should wait before starting.");
	votingCount = CreateConVar("sm_amongus_votingtimer", "30", "Sets how many seconds a vote should last before ejection.");
	ejectionCount = CreateConVar("sm_amongus_ejectiontimer", "10", "Sets how many seconds ejection should last.");
	anonymousEjection = CreateConVar("sm_amongus_anonymousejection", "0", "Enable (1) or disable (0) anonymous ejection.");
	RegAdminCmd("sm_amongus_becomeimpostor", Command_BecomeImpostor, ADMFLAG_SLAY|ADMFLAG_CHEATS, "sm_becomeimpostor <#userid|name>");
	g_hHud = CreateHudSynchronizer();
	//we want people to use the voice menu as a way to sabotage or report a body
	AddCommandListener(Listener_Voice, "voicemenu");
	//we only want people to type in chat if they are allowed to (and if they can see it)
	AddCommandListener(Listener_Chat, "say");
	AddCommandListener(Listener_Chat, "say_team");
	//we don't wan't people killing themselves
	AddCommandListener(Listener_Death, "kill");
	AddCommandListener(Listener_Death, "explode");
	//AddCommandListener(Listener_Death, "hurtme"); //disabled for debug do we really need this?
}

public Action:Listener_Voice(client, const String:command[], argc)
{
	if(playerState[client] == State_Ghost || playerState[client] == State_ImpostorGhost)
		return Plugin_Handled;
	int entity = GetClientAimTarget(client, false);
	decl String:targetname[128];
	int skin;
	if (IsValidEntity(entity))
	{
		GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
		skin = GetEntProp(entity, Prop_Data, "m_nSkin");
		if(StrEqual(targetname,"deadbody",true))
		{
			AcceptEntityInput(entity, "ClearParent");
			AcceptEntityInput(entity, "Kill");
			StartMeeting(client, Reason_FoundBody, skin);
		}
	}
	return Plugin_Handled;
}

//make sure the round doesn't linger when people leave
public Action:Event_PlayerDisconnect(Handle:event, String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(playerState[client] == State_Impostor)
		activeImpostors--;
	if(activeImpostors == 0) //still 0? player was last impostor
		RoundWon(State_Crewmate);
	else if(GetNonGhostTeamCount(TFTeam_Red)-1 <= 1)
		RoundWon(State_Impostor);
	return Plugin_Handled;
}

//chat when appropriate
public Action:Listener_Chat(client, const String:command[], argc)
{
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
						CPrintToChatEx(i, client, "{default}*Impostor* %s%N{default} :  %s", chatColor, client, newSpeech);
				}
				case State_Ghost:
				{
					if(playerState[i] == State_Ghost || playerState[i] == State_ImpostorGhost)
						CPrintToChatEx(i, client, "{default}(GHOST) %s%N{default} :  %s", chatColor, client, newSpeech);
				}
				case State_ImpostorGhost:
				{
					if(playerState[i] == State_Ghost)
						CPrintToChatEx(i, client, "{default}(GHOST) %s%N{default} :  %s", chatColor, client, newSpeech);
					else if(playerState[i] == State_ImpostorGhost)
						CPrintToChatEx(i, client, "{default}(GHOST) *Impostor* %s%N{default} :  %s", chatColor, client, newSpeech);
				}
			}
		}
	}
	return Plugin_Handled;
}

//set player to spy upon spawn
public Action OnPlayerSpawn(Handle hEvent, char[] strEventName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	if (!IsValidClient(iClient)) return;
	TF2_ChangeClientTeam(iClient,TFTeam_Red);
	TFClassType iClass = TF2_GetPlayerClass(iClient);
	if (!(iClass == view_as<TFClassType>(TFClass_Unknown)))
	{
		TF2_SetPlayerClass(iClient, TFClass_Spy, false, true);
		TF2_RegeneratePlayer(iClient);
	}
	TF2_RemoveWeaponSlot(iClient,0); //revolver
	//notably absent: sapper at slot 1, see below
	TF2_RemoveWeaponSlot(iClient,2); //knife
	TF2_RemoveWeaponSlot(iClient,3); //disguise kit?
	TF2_RemoveWeaponSlot(iClient,4); //why are
	TF2_RemoveWeaponSlot(iClient,5); //there seven
	TF2_RemoveWeaponSlot(iClient,6); //weapon slots
	new weapon = GetPlayerWeaponSlot(iClient, 1); //switch to sapper, we only want players to use the sapper otherwise they could just kill eachother outright with friendly fire
	//also noteworthy: the sapper will be used for tasks and shouldn't be replaced as I want to hook into sapper placement
	SetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon", weapon);
}
 
public int VoteHandler1 (Menu menu, MenuAction action, int param1, int param2)
{
	char info[32];
	menu.GetItem(param2, info, sizeof(info));
	if (action == MenuAction_Select)
	{
		if(alreadyVoted[param1] != 1 && g_votingState == VotingState_Voting)
		{
			int votedFor = GetClientOfUserId(votePlayerCorelation[StringToInt(info)]);
			char chatColor[MAX_NAME_LENGTH];
			SkinSwitch(param1, Skin_ChatColor, chatColor);
			if(votedFor > 0)
			{
				voteStorage[votedFor] += 1;
				char chatColor2[MAX_NAME_LENGTH];
				SkinSwitch(votedFor, Skin_ChatColor, chatColor);
				CPrintToChatAll("{default}* %s%N {default}has voted for %s%N{default}!",chatColor,param1,chatColor2,votedFor);
			}
			else //assume you voted skip
			{
				voteStorage[MAXPLAYERS+1] += 1;
				CPrintToChatAll("{default}* %s%N {default}has voted to skip!",chatColor,param1);
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
			IntToString(i+1,itemnum,2);
			char nameOfBody[MAX_NAME_LENGTH];
			SkinSwitch(i, Skin_Name, nameOfBody);
			if((playerState[i] == State_Impostor && playerState[client] == State_Impostor) || (playerState[i] == State_ImpostorGhost && playerState[client] == State_ImpostorGhost))
				Format(name,MAX_NAME_LENGTH,"%N (%s) (Impostor)", i, nameOfBody);
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
	currentMeeting = reason;
	if(g_votingState != VotingState_NoVote)
		return;
	if(reason == Reason_NoMeeting)
		return;
	int iSkin = 0; //0 - 11
	char nameOfBody[MAX_NAME_LENGTH];

	switch(skinOfBody)
	{
		case 0:
			Format(nameOfBody, 32, "Red"); //red
		case 1:
			Format(nameOfBody, 32, "Blue"); //blue
		case 2:
			Format(nameOfBody, 32, "Black"); //black
		case 3:
			Format(nameOfBody, 32, "Brown"); //brown
		case 4:
			Format(nameOfBody, 32, "Cyan"); //cyan
		case 5:
			Format(nameOfBody, 32, "Green"); //green
		case 6:
			Format(nameOfBody, 32, "Lime"); //lime
		case 7:
			Format(nameOfBody, 32, "Orange"); //orange
		case 8:
			Format(nameOfBody, 32, "Pink"); //pink
		case 9:
			Format(nameOfBody, 32, "Purple"); //purple
		case 10:
			Format(nameOfBody, 32, "White"); //white
		case 11:
			Format(nameOfBody, 32, "Yellow"); //yellow
		default:
			Format(nameOfBody, 32, "someone");
	}
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
					PrintCenterText(Client,"%N has found %s's dead body!",announcer,nameOfBody);
					EmitSoundToClient(Client,FOUNDBODY_SOUND);
				}
				case Reason_EmergencyButton:
				{
					PrintCenterText(Client,"%N has called for an emergency meeting!",announcer);
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
	Format(voteAnnouncer,MAX_NAME_LENGTH,"%N",announcer);
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
				}
			}
			voteStorage[MAXPLAYERS+1] = 0; //clear skip votes
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
					if(playerState[i] == State_Impostor)
						g_knifeCount[i] = knifeConVarCount.IntValue;
					switch(playerState[i])
					{
						case State_Ghost:
							SetEntityMoveType(firstVote, MOVETYPE_NOCLIP);
						case State_ImpostorGhost:
							SetEntityMoveType(firstVote, MOVETYPE_NOCLIP);
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

stock GetRealClientCount() {
	new iClients = 0;

	for (new i = 1; i <= MaxClients; i++) {
		if (IsValidClient(i)) {
			iClients++;
		}
	}

	return iClients;
} 

public Action GameStart(Handle event, char[] name, bool:Broadcast) {
	g_hWeaponEquip = EndPrepSDKCall();
	if (!g_hWeaponEquip)
	{
		SetFailState("Failed to prepare the SDKCall for giving weapons. Try updating gamedata or restarting your server.");
	}
	if(activeImpostors <= 0)
		activeImpostors = impostorCount.IntValue; //set the value initially
	firstVote = 0;
	secondVote = 0;
	currentMeeting = Reason_NoMeeting;
	g_votingState = VotingState_NoVote;
	voteStorage[MAXPLAYERS+1] = 0; //clear skip votes
	//we need to fill this table once more?
	g_aSpawnPoints = new ArrayList();
	int ent = -1;
	while((ent = FindEntityByClassname(ent, "info_player_teamspawn")) != -1)
	{
		g_aSpawnPoints.Push(ent);
	}
	//find out who is the impostor if there are enough players
	if(GetTeamClientCount(view_as<int>(TFTeam_Red)) >= (2*impostorCount.IntValue))
	{
		int iSkin = 0; //0 - 11
		for(new Client = 1; Client <= MaxClients; Client++)
		{
			if(IsValidClient(Client) && TF2_GetClientTeam(Client) == TFTeam_Red)
			{
				//let's play: how much of this can be moved to OnPlayerSpawn? ready? see you in major version 1
				EmitSoundToClient(Client, SPAWN_SOUND); //among who
				g_knifeCount[Client] = -1; //crewmates shouldn't have a knife count
				PrintCenterText(Client,"You are a crewmate!");
				voteStorage[Client] = 0;
				playerState[Client] = State_Crewmate;
				SDKUnhook(Client,SDKHook_SetTransmit,Hook_SetTransmit);
				SDKUnhook(Client, SDKHook_OnTakeDamage, OnTakeDamage);
				if(persistentUITimer[Client] != INVALID_HANDLE)
					KillTimer(persistentUITimer[Client],false); //kill or suffer the pain of eventual near-instant timers 
				persistentUITimer[Client] = CreateTimer(1.0, UITimer, GetClientUserId(Client), TIMER_REPEAT); //this should be the one and only UI timer for the client, for now
				SetVariantString(SPY_MODEL); //let's get our custom model in
				AcceptEntityInput(Client, "SetCustomModel"); //yeah set it in place :)
				SetEntProp(Client, Prop_Send, "m_bUseClassAnimations", 1); //enable animations otherwise you will be threatened by the living dead
				SetEntProp(Client, Prop_Send, "m_bForcedSkin", 1); //enable changing the skin
				SetEntProp(Client, Prop_Send, "m_nForcedSkin", iSkin); //set the skin
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
			
			playerState[randomClient] = State_Impostor;
			PrintCenterText(randomClient,"You are an impostor!");
			g_knifeCount[randomClient] = knifeConVarCount.IntValue;
			int glow = TF2_AttachBasicGlow(randomClient, TFTeam_Red); //impostors get a nice glow effect
			SetEntityRenderColor(glow, 255, 0, 0, 0);
			SDKHook(glow,SDKHook_SetTransmit,Hook_SetTransmitImpostor);
		}
	}
	else
	{
		PrintCenterTextAll("There are not enough players for %d impostor(s)! (%d/%d)",impostorCount.IntValue,GetTeamClientCount(view_as<int>(TFTeam_Red)),(2*impostorCount.IntValue));
	}
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

public Action:Listener_Death(client, const String:command[], argc)
{
	return Plugin_Handled; //when the player uses 'kill' or 'explode' we don't want to do anything
}

public Action UITimer(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidClient(client) || !IsPlayerAlive(client)) return Plugin_Stop;
	if (g_knifeCount[client] == 0) //the only way to have a knifecount > -1 is if you killed someone (>^-^)>
	{
		EmitSoundToClient(client, RECHARGE_SOUND);
		g_knifeCount[client]--; //go to -1 so we don't decrement anymore
		TF2Items_GiveWeapon(client, 4);
		new weapon = GetPlayerWeaponSlot(client, 1); //switch to sapper
		SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", weapon);
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
			ShowSyncHudText(client, g_hHud, "Discuss!\n%s has started the vote!\n%d seconds until voting starts.",voteAnnouncer,voteCounter[client]);
		}
		case VotingState_Voting:
		{
			SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
			ShowSyncHudText(client, g_hHud, "Vote now!\n%s has started the vote!\n%d seconds until voting ends.",voteAnnouncer,voteCounter[client]);
		}
		case VotingState_Ejection:
		{
			SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
			switch(currentMeeting)
			{
				case Reason_Anonymous:
					ShowSyncHudText(client, g_hHud, "%N was ejected.\n%d seconds until ejection ends.",firstVote,voteCounter[client]);
				case Reason_Crewmate:
					ShowSyncHudText(client, g_hHud, "%N was not an impostor.\n%d impostor(s) remain.\n%d seconds until ejection ends.",firstVote,activeImpostors,voteCounter[client]);
				case Reason_Impostor:
					ShowSyncHudText(client, g_hHud, "%N was an impostor.\n%d impostor(s) remain.\n%d seconds until ejection ends.",firstVote,activeImpostors,voteCounter[client]);
				case Reason_Tie:
					ShowSyncHudText(client, g_hHud, "No one was ejected. (Tie)\n%d seconds until ejection ends.",voteCounter[client]);
				case Reason_Skip:
					ShowSyncHudText(client, g_hHud, "No one was ejected. (Skipped)\n%d seconds until ejection ends.",voteCounter[client]);
				case Reason_Disconnected:
					ShowSyncHudText(client, g_hHud, "No one was ejected. (Player disconnected)\n%d seconds until ejection ends.",voteCounter[client]);
				default:
					ShowSyncHudText(client, g_hHud, "%d seconds until ejection ends.",voteCounter[client]);
			}
		}
		default:
		{
			switch(playerState[client])
			{
				case (State_Crewmate):
				{
					SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
					ShowSyncHudText(client, g_hHud, "Tasks:");
				}
				case (State_Impostor):
				{
					SetHudTextParams(0.15, 0.15, 3.0, 255, 0, 0, 255, 1, 6.0, 0.1, 0.1);
					if (g_knifeCount[client] > 1)
						ShowSyncHudText(client, g_hHud, "You can use your knife in %d seconds.\nSabotage and kill everyone.\nFake Tasks:",g_knifeCount[client]);
					else if (g_knifeCount[client] > 0)
						ShowSyncHudText(client, g_hHud, "You can use your knife in %d second.\nSabotage and kill everyone.\nFake Tasks:",g_knifeCount[client]);
					else
						ShowSyncHudText(client, g_hHud, "Sabotage and kill everyone.\nFake Tasks:",g_knifeCount[client]);
				}
				case (State_ImpostorGhost):
				{
					SetHudTextParams(0.15, 0.15, 3.0, 255, 0, 0, 255, 1, 6.0, 0.1, 0.1);
					ShowSyncHudText(client, g_hHud, "You are dead.\nYou can still sabotage.");
				}
				default:
				{
					SetHudTextParams(0.15, 0.15, 3.0, 255, 255, 255, 255, 1, 6.0, 0.1, 0.1);
					ShowSyncHudText(client, g_hHud, "You are dead.\nFinish your tasks to win!\nTasks:");
				}
			}
		}
	}
	
	return Plugin_Continue;
}

//impostor has hurt someone! (friendly fire must be on)
public Action:OnTakeDamage(client, &attacker, &inflictor, &Float:damage, &damagetype)
{
	if(playerState[client] == State_Impostor)
		return Plugin_Handled;
	if(g_votingState != VotingState_NoVote)
		return Plugin_Handled;
	new Float:vOrigin[3];
	float seqAngles[3];
	if(playerState[client] != State_Ghost)
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

		if(IsValidClient(attacker))
		{
			EmitSoundToClient(attacker, KILL_SOUND);
			g_knifeCount[attacker] = knifeConVarCount.IntValue;
			TF2_RemoveWeaponSlot(attacker,2);
			SetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon", GetPlayerWeaponSlot(attacker, 1));
			ApplyGhostEffect(client, GhostReason_Killed);
		}
		else
			ApplyGhostEffect(client, GhostReason_Suicide);
		if(GetNonGhostTeamCount(TFTeam_Red)-activeImpostors <= 1)
			RoundWon(State_Impostor);
	}
	return Plugin_Handled;
}

public Action:Hook_SetTransmitImpostor(entity, client)
{
	int ent = GetEntPropEnt(entity, Prop_Data, "m_hEffectEntity");
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

public Action:Hook_SetTransmit(entity, client)
{
	if (entity == client || playerState[client] == State_Ghost || playerState[client] == State_ImpostorGhost)
		return Plugin_Continue;
	return Plugin_Handled;
}

public void RoundWon(PlayerState winners)
{
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
			PrintCenterTextAll("Crewmates win!");
		}
		case (State_Impostor):
		{
			SetVariantInt(3);
			PrintCenterTextAll("Impostors win!");
		}
		default:
		{
			SetVariantInt(0);
			PrintCenterTextAll("Nobody wins...");
		}
	}
	DispatchKeyValue(iEnt,"force_map_reset","1");
	AcceptEntityInput(iEnt, "SetTeam");
	AcceptEntityInput(iEnt, "RoundWin");
	for(int i = 0; i < MaxClients; i++)
	{
		if(IsValidClient(i))
			persistentUITimer[i] = INVALID_HANDLE;
	}
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
public Action Command_BecomeImpostor(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_becomeimpostor <#userid|name>");
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
	
	for (int i = 0; i < target_count; i++)
	{
		LogAction(client, target_list[i], "\"%L\" set \"%L\" as an impostor!", client, target_list[i]);
		//activeImpostors++;
		playerState[target_list[i]] = State_Impostor;
		g_knifeCount[target_list[i]] = 0;
	}
	
	return Plugin_Handled;
}

public Action:TF2Items_OnGiveNamedItem(client, String:classname[], iItemDefinitionIndex, &Handle:hItem)
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

public void SkinSwitch(int client, SkinSwitchType type, char[] chatColor)
{
	if(!IsValidClient(client))
		return;
	switch(g_playerSkin[client])
	{
		case 0:
		{
			switch(type)
			{
				case Skin_ChatColor:
					Format(chatColor, 32, "{red}");
				case Skin_Name:
					Format(chatColor, 32, "Red");
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
					Format(chatColor, 32, "Blue");
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
					Format(chatColor, 32, "Black");
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
					Format(chatColor, 32, "Brown");
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
					Format(chatColor, 32, "Cyan");
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
					Format(chatColor, 32, "Green");
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
					Format(chatColor, 32, "Lime");
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
					Format(chatColor, 32, "Orange");
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
					Format(chatColor, 32, "Pink");
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
					Format(chatColor, 32, "Purple");
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
					Format(chatColor, 32, "White");
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
					Format(chatColor, 32, "Yellow");
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
					Format(chatColor, 32, "someone");
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
			PrintCenterText(client,"You have been killed!");
		case GhostReason_Suicide:
			PrintCenterText(client,"You died on your own!");
		case GhostReason_Ejected:
			PrintCenterText(client,"You have been ejected!");
		default:
			PrintCenterText(client,"You died!");
	}
	SDKHook(client,SDKHook_SetTransmit,Hook_SetTransmit);
	SetEntityMoveType(client, MOVETYPE_NOCLIP);
	SkinSwitchC(client);
}
