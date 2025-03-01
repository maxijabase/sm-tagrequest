#include <sourcemod>
#include <ccc>
#include <xVip>

#undef REQUIRE_PLUGIN
#include <updater>

#define UPDATE_URL "https://raw.githubusercontent.com/maxijabase/xVip_tagrequest/master/updatefile.txt"

#pragma semicolon 1
#pragma newdecls required

Database g_DB;
bool g_Late;
bool g_Spawned[MAXPLAYERS + 1];

public Plugin myinfo = {
  name = "xVip - Tag Request", 
  author = "ampere", 
  description = "Allows players to submit a CCC tag request for admins to approve or deny.", 
  version = "1.3", 
  url = "github.com/maxijabase"
}

enum RequestState {
  RequestState_Pending = 0, 
  RequestState_Approved, 
  RequestState_Denied, 
  RequestState_Finished
};

char g_RequestStateNames[][] = {
  "pending", 
  "approved", 
  "denied", 
  "finished"
};

enum struct TagRequest {
  char steamid[32];
  char name[MAX_NAME_LENGTH];
  char oldtag[32];
  char newtag[32];
  int timestamp;
  RequestState state;
}

ArrayList g_Requests;
TagRequest g_SelectedRequest;

// ======= [FORWARDS] ======= //

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
  g_Late = late;
  return APLRes_Success;
}

public void OnPluginStart() {
  Database.Connect(SQL_Connection, "xVip");
  
  HookEvent("player_team", OnClientJoinTeam);
  
  RegConsoleCmd("sm_tagrequest", CMD_TagRequest, "Makes a tag change request.");
  RegAdminCmd("sm_tagrequests", CMD_SeeTagRequests, ADMFLAG_GENERIC, "Lists all the tag requests.");
  
  LoadTranslations("common.phrases");
  LoadTranslations("xVip_tagrequest.phrases");
  
  g_Requests = new ArrayList(sizeof(TagRequest));
}

public void Updater_OnLoaded() {
  Updater_AddPlugin(UPDATE_URL);
}

public void OnMapStart() {
  CacheRequests();
}

public void OnClientPostAdminCheck(int client) {
  g_Spawned[client] = false;
}

public void OnClientDisconnect(int client) {
  g_Spawned[client] = false;
}

public void OnClientJoinTeam(Event event, const char[] name, bool dontBroadcast) {
  int userid = event.GetInt("userid");
  int client = GetClientOfUserId(userid);
  
  if (!IsValidClient(client)) {
    return;
  }
  
  if (g_Spawned[client]) {
    return;
  }
  CheckPendingMessages(client);
  g_Spawned[client] = true;
}

// ======= [COMMANDS] ======= //

public Action CMD_TagRequest(int client, int args) {
  if (!IsValidClient(client)) {
    return Plugin_Handled;
  }
  
  if (!xVip_IsVip(client)) {
    xVip_Reply(client, "%t", "NotVip");
    return Plugin_Handled;
  }
  
  if (args == 0) {
    xVip_Reply(client, "Usage: sm_tagrequest <tag>");
    return Plugin_Handled;
  }
  
  char steamid[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid))) {
    xVip_Reply(client, "Error: Could not retrieve your Steam ID.");
    return Plugin_Handled;
  }
  
  char requestedTag[32];
  GetCmdArgString(requestedTag, sizeof(requestedTag));
  
  if (requestedTag[0] == '\0') {
    xVip_Reply(client, "Error: Tag cannot be empty.");
    return Plugin_Handled;
  }
  
  char pendingTag[32];
  GetPendingTag(steamid, pendingTag, sizeof(pendingTag));
  if (pendingTag[0] != '\0') {
    xVip_Reply(client, "%t", "PendingRequest", pendingTag);
    return Plugin_Handled;
  }
  
  char currentTag[32];
  CCC_GetTag(client, currentTag, sizeof(currentTag));
  if (StrEqual(requestedTag, currentTag)) {
    xVip_Reply(client, "%t", "TagsAreEqual");
    return Plugin_Handled;
  }
  
  TagRequest req;
  
  strcopy(req.steamid, sizeof(req.steamid), steamid);
  GetClientName(client, req.name, sizeof(req.name));
  strcopy(req.oldtag, sizeof(req.oldtag), currentTag);
  strcopy(req.newtag, sizeof(req.newtag), requestedTag);
  req.timestamp = GetTime();
  req.state = RequestState_Pending;
  
  char query[512];
  char escapedName[MAX_NAME_LENGTH * 2 + 1];
  char escapedOldTag[64 + 1];
  char escapedNewTag[64 + 1];
  
  if (g_DB == null) {
    xVip_Reply(client, "Error: Database connection not available. Try again later.");
    return Plugin_Handled;
  }
  
  g_DB.Escape(req.name, escapedName, sizeof(escapedName));
  g_DB.Escape(req.oldtag, escapedOldTag, sizeof(escapedOldTag));
  g_DB.Escape(req.newtag, escapedNewTag, sizeof(escapedNewTag));
  
  TrimString(req.newtag);
  Format(req.newtag, sizeof(req.newtag), "%s ", req.newtag);
  
  g_DB.Format(query, sizeof(query), 
    "INSERT INTO xVip_tagrequests (steamid, name, current_tag, desired_tag, timestamp, state) VALUES "...
    "('%s', '%s', '%s', '%s', UNIX_TIMESTAMP(), '%s')", 
    req.steamid, escapedName, escapedOldTag, escapedNewTag, g_RequestStateNames[view_as<int>(req.state)]);
  
  DataPack pack = new DataPack();
  pack.WriteCell(GetClientUserId(client));
  pack.WriteCellArray(req, sizeof(req));
  
  g_DB.Query(SQL_InsertRequest, query, pack);
  
  return Plugin_Handled;
}

public Action CMD_SeeTagRequests(int client, int args) {
  if (!IsValidClient(client)) {
    return Plugin_Handled;
  }
  
  if (g_Requests.Length == 0) {
    xVip_Reply(client, "%t", "NoRequests");
  }
  else {
    CreateRequestsMenu(client);
  }
  
  return Plugin_Handled;
}

// ======= [METHODS] ======= //

void CacheRequests() {
  if (g_DB == null) {
    LogError("CacheRequests: Database connection not available");
    return;
  }
  
  g_Requests.Clear();
  
  char query[128];
  g_DB.Format(query, sizeof(query), "SELECT * FROM xVip_tagrequests WHERE state != 'finished'");
  
  g_DB.Query(SQL_CacheRequests, query);
}

void CreateRequestsMenu(int client) {
  Menu menu = new Menu(RequestsMenuHandler);
  menu.SetTitle("%t", "Str_TagRequests");
  
  int pendingCount = 0;
  
  for (int i = 0; i < g_Requests.Length; i++) {
    TagRequest req;
    g_Requests.GetArray(i, req, sizeof(req));
    
    if (req.state == RequestState_Pending) {
      char indexStr[16];
      IntToString(i, indexStr, sizeof(indexStr));
      menu.AddItem(indexStr, req.name);
      pendingCount++;
    }
  }
  
  if (pendingCount == 0) {
    xVip_Reply(client, "%t", "NoRequests");
    delete menu;
    return;
  }
  menu.ExitButton = true;
  menu.Display(client, MENU_TIME_FOREVER);
}

void GetPendingTag(const char[] steamid, char[] buffer, int maxsize) {
  TagRequest req;
  for (int i = 0; i < g_Requests.Length; i++) {
    g_Requests.GetArray(i, req, sizeof(req));
    if (StrEqual(req.steamid, steamid) && req.state == RequestState_Pending) {
      strcopy(buffer, maxsize, req.newtag);
      return;
    }
  }
  buffer[0] = '\0';
}

void CheckPendingMessages(int client) {
  char steamid[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid))) {
    return;
  }
  
  int totalPendingRequests = 0;
  
  if (!IsValidClient(client)) {
    return;
  }
  
  for (int i = 0; i < g_Requests.Length; i++) {
    TagRequest req;
    g_Requests.GetArray(i, req, sizeof(req));
    
    if (StrEqual(req.steamid, steamid)) {
      switch (req.state) {
        case RequestState_Pending: {
          totalPendingRequests++;
        }
        
        case RequestState_Approved, RequestState_Denied: {
          g_SelectedRequest = req;
          SendInfoPanel(client, req.state == RequestState_Approved ? "approved" : "denied");
          
          if (req.state == RequestState_Approved) {
            SetClientTag(req, client);
          }
          
          UpdateRequest(RequestState_Finished, client);
        }
      }
    }
  }
  
  if (totalPendingRequests > 0 && CheckCommandAccess(client, "sm_admin", ADMFLAG_GENERIC)) {
    xVip_Reply(client, "%t", "ThereArePendingRequests", client, totalPendingRequests);
  }
}

void UpdateRequest(RequestState newState, int client) {
  if (g_DB == null) {
    LogError("UpdateRequest: Database connection not available");
    return;
  }
  
  char query[512];
  g_DB.Format(query, sizeof(query), 
    "UPDATE xVip_tagrequests SET state = '%s' WHERE steamid = '%s' AND desired_tag = '%s' "...
    "AND timestamp = (SELECT MAX(timestamp) FROM xVip_tagrequests t2 WHERE t2.steamid = '%s' AND t2.desired_tag = '%s')", 
    g_RequestStateNames[view_as<int>(newState)], g_SelectedRequest.steamid, g_SelectedRequest.newtag, 
    g_SelectedRequest.steamid, g_SelectedRequest.newtag);
  
  DataPack pack = new DataPack();
  pack.WriteCell(view_as<int>(newState));
  pack.WriteCell(client != 0 ? GetClientUserId(client) : 0);
  
  g_DB.Query(SQL_StatusUpdate, query, pack);
}

void SendInfoPanel(int client, const char[] stateStr) {
  if (!IsValidClient(client)) {
    return;
  }
  
  Panel panel = new Panel();
  panel.SetTitle("Tag Request");
  char line1[64], phrase[16], exitStr[16];
  Format(phrase, sizeof(phrase), StrEqual(stateStr, "approved") ? "TagApprovedUser" : "TagDeniedUser");
  Format(line1, sizeof(line1), "%t", phrase, g_SelectedRequest.newtag);
  Format(exitStr, sizeof(exitStr), "%t", "Str_Exit");
  panel.DrawText(line1);
  panel.DrawText(" ");
  panel.CurrentKey = 10;
  panel.DrawItem(exitStr);
  panel.Send(client, EmptyHandler, MENU_TIME_FOREVER);
}

void SetRequestState(const char[] steamid, RequestState newState) {
  for (int i = 0; i < g_Requests.Length; i++) {
    TagRequest req;
    g_Requests.GetArray(i, req, sizeof(req));
    if (StrEqual(req.steamid, steamid) && StrEqual(req.newtag, g_SelectedRequest.newtag)) {
      if (newState == RequestState_Finished) {
        g_Requests.Erase(i);
      }
      else {
        req.state = newState;
        g_Requests.SetArray(i, req, sizeof(req));
      }
      return;
    }
  }
}

void ShowRequestDetailsPanel(int client) {
  Panel panel = new Panel();
  char panelTitle[32];
  Format(panelTitle, sizeof(panelTitle), "%t", "Str_ShowingTagRequestOfUser", g_SelectedRequest.name);
  panel.SetTitle(panelTitle);
  
  char line1[64], line2[64], line3[64], time[64];
  
  Format(line1, sizeof(line1), "%t", "Str_CurrentTag", g_SelectedRequest.oldtag);
  Format(line2, sizeof(line2), "%t", "Str_NewTag", g_SelectedRequest.newtag);
  FormatTime(time, sizeof(time), "%b %d, %Y %R", g_SelectedRequest.timestamp);
  Format(line3, sizeof(line3), "%t", "Str_DateRequested", time);
  panel.DrawText(" ");
  panel.DrawText(line1);
  panel.DrawText(line2);
  panel.DrawText(line3);
  panel.DrawText(" ");
  
  char approve[32], deny[32], back[16], exitStr[16];
  
  Format(approve, sizeof(approve), "%t", "Str_ApproveTag");
  Format(deny, sizeof(deny), "%t", "Str_DenyTag");
  Format(back, sizeof(back), "%t", "Str_Back");
  Format(exitStr, sizeof(exitStr), "%t", "Str_Exit");
  panel.DrawItem(approve);
  panel.DrawItem(deny);
  panel.CurrentKey = 9;
  panel.DrawItem(back);
  panel.DrawItem(exitStr);
  
  panel.Send(client, RequestDetailsPanelHandler, MENU_TIME_FOREVER);
}

void SetClientTag(TagRequest req, int client) {
  if (g_DB == null || !IsValidClient(client)) {
    LogError("SetClientTag: Database connection not available or invalid client");
    return;
  }
  
  char escaped_tag[64];
  g_DB.Escape(req.newtag, escaped_tag, sizeof(escaped_tag));
  
  char query[512];
  g_DB.Format(query, sizeof(query), 
    "INSERT INTO cccm_users (steamid, tagtext) VALUES ('%s', '%s') ON DUPLICATE KEY UPDATE tagtext = '%s'", 
    req.steamid, escaped_tag, escaped_tag);
  
  CCC_SetTag(client, req.newtag);
  g_DB.Query(SQL_SetTag, query);
}

int FindClientBySteamID(const char[] steamid) {
  char clientSteamID[32];
  
  for (int i = 1; i <= MaxClients; i++) {
    if (IsValidClient(i) && GetClientAuthId(i, AuthId_Steam2, clientSteamID, sizeof(clientSteamID))) {
      if (StrEqual(steamid, clientSteamID)) {
        return i;
      }
    }
  }
  
  return -1;
}

// ======= [MENU HANDLERS] ======= //

public int RequestsMenuHandler(Menu menu, MenuAction action, int client, int param2) {
  switch (action) {
    case MenuAction_Select: {
      char indexStr[16];
      menu.GetItem(param2, indexStr, sizeof(indexStr));
      int index = StringToInt(indexStr);
      
      if (index >= 0 && index < g_Requests.Length) {
        g_Requests.GetArray(index, g_SelectedRequest, sizeof(g_SelectedRequest));
        ShowRequestDetailsPanel(client);
      } else {
        xVip_Reply(client, "Error: The selected request is no longer available.");
        CreateRequestsMenu(client);
      }
    }
    case MenuAction_End: {
      delete menu;
    }
  }
  return 0;
}

public int RequestDetailsPanelHandler(Menu menu, MenuAction action, int param1, int param2) {
  switch (action) {
    case MenuAction_Select: {
      switch (param2) {
        case 1: {
          UpdateRequest(RequestState_Approved, param1);
        }
        case 2: {
          UpdateRequest(RequestState_Denied, param1);
        }
        case 9: {
          CreateRequestsMenu(param1);
        }
        default: {
          delete menu;
        }
      }
    }
    case MenuAction_End: {
      delete menu;
    }
  }
  return 0;
}

public int EmptyHandler(Menu menu, MenuAction action, int param1, int param2) {
  if (action == MenuAction_End) {
    delete menu;
  }
  return 0;
}

// ======= [SQL CALLBACKS] ======= //

public void SQL_SetTag(Database db, DBResultSet results, const char[] error, any data) {
  if (db == null || error[0] != '\0') {
    LogError("SQL_SetTag callback: %s", error);
    return;
  }
}

public void SQL_StatusUpdate(Database db, DBResultSet results, const char[] error, DataPack pack) {
  if (db == null || error[0] != '\0') {
    LogError("StatusUpdate callback: %s", error);
    delete pack;
    return;
  }
  
  pack.Reset();
  RequestState newState = view_as<RequestState>(pack.ReadCell());
  int admin_userid = pack.ReadCell();
  int admin_client = GetClientOfUserId(admin_userid);
  delete pack;
  
  SetRequestState(g_SelectedRequest.steamid, newState);
  
  // If this is an approve/deny from an admin, notify the requesting player immediately
  if (newState == RequestState_Approved || newState == RequestState_Denied) {
    int target_client = FindClientBySteamID(g_SelectedRequest.steamid);
    
    if (IsValidClient(target_client)) {
      SendInfoPanel(target_client, newState == RequestState_Approved ? "approved" : "denied");
      
      if (newState == RequestState_Approved) {
        SetClientTag(g_SelectedRequest, target_client);
      }
      
      // Mark as finished in DB and remove from local array
      UpdateRequest(RequestState_Finished, 0);
    }
    
    // Notify admin
    char phrase[32];
    strcopy(phrase, sizeof(phrase), newState == RequestState_Approved ? "TagApprovedAdmin" : "TagDeniedAdmin");
    
    if (admin_client > 0 && IsClientInGame(admin_client)) {
      xVip_Reply(admin_client, "%t", phrase, g_SelectedRequest.newtag);
      CreateRequestsMenu(admin_client);
    }
  }
}

public void SQL_CacheRequests(Database db, DBResultSet results, const char[] error, any data) {
  if (db == null || error[0] != '\0') {
    LogError("Cache requests callback: %s", error);
    return;
  }
  
  if (results.RowCount == 0) {
    return;
  }
  
  int steamidCol, nameCol, currtagCol, wantedtagCol, timestampCol, stateCol;
  results.FieldNameToNum("steamid", steamidCol);
  results.FieldNameToNum("name", nameCol);
  results.FieldNameToNum("current_tag", currtagCol);
  results.FieldNameToNum("desired_tag", wantedtagCol);
  results.FieldNameToNum("timestamp", timestampCol);
  results.FieldNameToNum("state", stateCol);
  
  while (results.FetchRow()) {
    TagRequest req;
    results.FetchString(steamidCol, req.steamid, sizeof(req.steamid));
    results.FetchString(nameCol, req.name, sizeof(req.name));
    results.FetchString(currtagCol, req.oldtag, sizeof(req.oldtag));
    results.FetchString(wantedtagCol, req.newtag, sizeof(req.newtag));
    req.timestamp = results.FetchInt(timestampCol);
    
    char stateStr[16];
    results.FetchString(stateCol, stateStr, sizeof(stateStr));
    
    // Convert state string to enum
    if (StrEqual(stateStr, "pending")) {
      req.state = RequestState_Pending;
    } else if (StrEqual(stateStr, "approved")) {
      req.state = RequestState_Approved;
    } else if (StrEqual(stateStr, "denied")) {
      req.state = RequestState_Denied;
    } else if (StrEqual(stateStr, "finished")) {
      req.state = RequestState_Finished;
    }
    
    g_Requests.PushArray(req);
  }
}

public void SQL_Connection(Database db, const char[] error, any data) {
  if (db == null) {
    SetFailState("Connection: %s", error);
    return;
  }
  
  g_DB = db;
  char tablesQuery[512] = 
  "CREATE TABLE IF NOT EXISTS xVip_tagrequests "...
  "(id INT NOT NULL AUTO_INCREMENT, "...
  "steamid VARCHAR(32), "...
  "name VARCHAR(64), "...
  "current_tag VARCHAR(32), "...
  "desired_tag VARCHAR(32), "...
  "timestamp int, "...
  "state VARCHAR(32), "...
  "PRIMARY KEY(id), "...
  "INDEX(steamid), "...
  "INDEX(state));";
  
  g_DB.Query(SQL_Tables, tablesQuery);
}

public void SQL_Tables(Database db, DBResultSet results, const char[] error, any data) {
  if (db == null || error[0] != '\0') {
    LogError("Tables callback: %s", error);
    return;
  }
  
  if (g_Late) {
    for (int i = 1; i <= MaxClients; i++) {
      if (IsValidClient(i)) {
        OnClientPostAdminCheck(i);
      }
    }
  }
  
  CacheRequests();
}

public void SQL_InsertRequest(Database db, DBResultSet results, const char[] error, DataPack pack) {
  pack.Reset();
  int client = GetClientOfUserId(pack.ReadCell());
  TagRequest req;
  pack.ReadCellArray(req, sizeof(req));
  delete pack;
  
  if (db == null || error[0] != '\0') {
    LogError("Insert request callback for %N: %s", client, error);
    if (IsValidClient(client)) {
      xVip_Reply(client, "Error: Could not submit your tag request. Please try again later.");
    }
    return;
  }
  
  g_Requests.PushArray(req);
  
  if (!IsValidClient(client)) {
    return;
  }
  
  xVip_Reply(client, "%t", "RequestSent", req.newtag);
  
  for (int i = 1; i <= MaxClients; i++) {
    if (IsValidClient(i) && CheckCommandAccess(i, "sm_admin", ADMFLAG_GENERIC)) {
      xVip_Reply(i, "%t", "NewTagRequest", req.name, req.newtag);
    }
  }
} 