stock int GetClientFromSteamID(const char[] steamid) {
	for (int i = 1; i <= MaxClients; i++) {
		char foundSteamID[32];
		if (IsClientConnected(i) && !IsFakeClient(i) && IsClientAuthorized(i) && GetClientAuthId(i, AuthId_Steam2, foundSteamID, sizeof(foundSteamID))) {
			if (StrEqual(foundSteamID, steamid)) {
				return i;
			}
		}
	}
	return -1;
}

stock void GetUserIdAsString(int client, char[] buffer, int maxsize) {
	IntToString(GetClientUserId(client), buffer, maxsize);
}