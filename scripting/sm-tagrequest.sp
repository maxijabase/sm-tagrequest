#include <sourcemod>
#include <morecolors>
#include <ccc>

#define PREFIX "{orange}[TagRequest]{default}"

Database g_DB;
bool g_bHasPendingRequest[MAXPLAYERS];
char g_cRequestedTag[64][MAXPLAYERS];
char g_cSteamID[32][MAXPLAYERS];

public Plugin myinfo = {
	
	name = "Tag Request", 
	author = "ampere", 
	description = "Allows players to submit a tag request for admins to approve or deny.", 
	version = "1.0", 
	url = "github.com/maxijabase"
	
}

// ======= [FORWARDS] ======= //

public void OnPluginStart() {
	Database.Connect(SQL_Connection, "cccm");
	RegAdminCmd("sm_tagrequest", CMD_TagRequest, ADMFLAG_GENERIC, "Makes a tag change request.");
	LoadTranslations("common.phrases");
	LoadTranslations("tagrequest.phrases");
}

public void OnClientPostAdminCheck(int client) {
	
	if (g_DB == null) {
		return;
	}
	
	GetClientAuthId(client, AuthId_Steam2, g_cSteamID[client], sizeof(g_cSteamID[]));
	int userid = GetClientUserId(client);
	
	char query[128];
	g_DB.Format(query, sizeof(query), "SELECT * FROM tag_requests WHERE steam_id = '%s'", g_cSteamID[client]);
	DataPack pack = new DataPack();
	pack.WriteCell(userid);
	
	g_DB.Query(SQL_CheckRequests, query, pack);
}

// ======= [COMMANDS] ======= //

public Action CMD_TagRequest(int client, int args) {
	if (g_bHasPendingRequest[client]) {
		MC_ReplyToCommand(client, "%t", "PendingRequest", PREFIX, g_cRequestedTag[client]);
		return Plugin_Handled;
	}
	
	if (args < 1) {
		MC_ReplyToCommand(client, "%s sm_tagrequest <tag>", PREFIX);
		return Plugin_Handled;
	}
	
	// Get desired tag
	char wantedTag[32];
	for (int i = 1; i <= GetCmdArgs(); i++) {
		char cusBuf[32];
		GetCmdArg(i, cusBuf, sizeof(cusBuf));
		Format(cusBuf, sizeof(cusBuf), "%s ", cusBuf);
		
		StrCat(wantedTag, sizeof(wantedTag), cusBuf);
	}
	
	// Get name
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	
	// Get current tag
	char currTag[32];
	CCC_GetTag(client, currTag, sizeof(currTag));
	
	char query[256];
	g_DB.Format(query, sizeof(query), 
		"INSERT INTO tag_requests (steam_id, name, current_tag, desired_tag, datetime, state) VALUES "...
		"('%s', '%s', '%s', '%s', UNIX_TIMESTAMP(), '%s')", g_cSteamID[client], name, currTag, wantedTag, "pending");
	
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteString(wantedTag);
	
	g_DB.Query(SQL_InsertRequest, query, pack);
	
	return Plugin_Handled;
}

// ======= [SQL CALLBACKS] ======= //

public void SQL_Connection(Database db, const char[] error, any data) {
	if (db == null) {
		SetFailState("Connection: %s", error);
		return;
	}
	
	LogMessage("Connection successful.");
	
	g_DB = db;
	char tablesQuery[256] = 
	"CREATE TABLE IF NOT EXISTS tag_requests "...
	"(id INT NOT NULL AUTO_INCREMENT, "...
	"steam_id VARCHAR(32), "...
	"name VARCHAR(32), "...
	"current_tag VARCHAR(32), "...
	"desired_tag VARCHAR(32), "...
	"datetime VARCHAR(32), "...
	"state VARCHAR(32), "...
	"PRIMARY KEY(id));";
	
	g_DB.Query(SQL_Tables, tablesQuery);
}

public void SQL_Tables(Database db, DBResultSet results, const char[] error, any data) {
	if (db == null || error[0] != '\0') {
		LogError("Tables callback: %s", error);
		return;
	}
	
	LogMessage("Tables creation successful.");
}

public void SQL_CheckRequests(Database db, DBResultSet results, const char[] error, DataPack pack) {
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	delete pack;
	
	if (db == null || error[0] != '\0') {
		LogError("Check request callback for %N: %s", client, error);
		return;
	}
	
	if (!results.FetchRow()) {
		PrintToServer("debug 1");
		g_bHasPendingRequest[client] = false;
		return;
	}
	
	int tagCol;
	results.FieldNameToNum("desired_tag", tagCol);
	results.FetchString(tagCol, g_cRequestedTag[client], sizeof(g_cRequestedTag[]));
	g_bHasPendingRequest[client] = true;
}

public void SQL_InsertRequest(Database db, DBResultSet results, const char[] error, DataPack pack) {
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	char wantedTag[32];
	pack.ReadString(wantedTag, sizeof(wantedTag));
	delete pack;
	
	if (db == null || error[0] != '\0') {
		LogError("Insert request callback for %N: %s", client, error);
		return;
	}
	
	g_bHasPendingRequest[client] = true;
	strcopy(g_cRequestedTag[client], sizeof(g_cRequestedTag[]), wantedTag);
	MC_PrintToChat(client, "%t", "RequestSent", PREFIX, wantedTag);
	
} 