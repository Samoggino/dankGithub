import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

QtObject {
    id: root

    property var pluginService: null
    property string trigger: "gh"
    signal itemsChanged

    readonly property string pluginId: "dankGithub"
    readonly property string githubIcon: "unicode:"
    readonly property string scriptPath: Qt.resolvedUrl("fetch-repos.sh").toString().replace("file://", "")

    property bool enabled: true
    property string username: ""
    property double tokenVersion: 0 // bumped by the settings page when the keyring token changes
    property bool showForks: true
    property bool showArchived: false
    property int refreshMinutes: 30
    property var hiddenRepos: [] // full_name of repos hidden from the launcher
    property var extraRepos: [] // "owner/name" of public repos added by hand in the settings

    property var cachedRepos: [] // [{ name, fullName, description, url, private, fork, archived, pushedAt }]
    property string lastFetchKey: "" // username + token used for the last fetch
    property double lastRefreshRequest: 0

    // ---- Fetching ----
    property var fetchProcess: Process {
        running: false
        command: ["bash", root.scriptPath]
        environment: ({
                "GH_USER": root.username,
                "GH_EXTRA": root.extraRepos.join("\n")
            })
        stdout: StdioCollector {
            onStreamFinished: root.parseOutput(text)
        }
    }

    function refresh() {
        if (!root.enabled || root.fetchProcess.running)
            return;
        root.setStatus("Refreshing...");
        root.fetchProcess.running = true;
    }

    function parseOutput(text) {
        const out = (text || "").trim();
        if (out.startsWith("ERR:")) {
            root.setStatus("Error: " + out.substring(4));
            console.warn("DankGithub:", out);
            return;
        }
        let repos = [];
        let missing = [];
        const extraSet = {};
        for (const e of root.extraRepos)
            extraSet[e.toLowerCase()] = true;
        try {
            const missingIdx = out.indexOf("@@MISSING@@");
            const body = missingIdx >= 0 ? out.substring(0, missingIdx) : out;
            if (missingIdx >= 0)
                missing = out.substring(missingIdx + 11).trim().split(/\s+/).filter(m => m);
            const seen = {};
            const pages = body.split("@@PAGE@@");
            for (const page of pages) {
                if (!page.trim())
                    continue;
                for (const r of JSON.parse(page)) {
                    if (!r || !r.full_name || seen[r.full_name])
                        continue;
                    seen[r.full_name] = true;
                    repos.push({
                        name: r.name,
                        fullName: r.full_name,
                        owner: r.owner ? r.owner.login : "",
                        description: r.description || "",
                        url: r.html_url,
                        cloneUrl: r.ssh_url || r.clone_url || "",
                        private: !!r.private,
                        fork: !!r.fork,
                        archived: !!r.archived,
                        pushedAt: r.pushed_at || "",
                        extra: !!extraSet[r.full_name.toLowerCase()]
                    });
                }
            }
        } catch (e) {
            root.setStatus("Error: cannot parse GitHub response");
            console.warn("DankGithub parse error:", e);
            return;
        }
        repos.sort((a, b) => (b.pushedAt || "").localeCompare(a.pushedAt || ""));
        root.cachedRepos = repos;
        if (root.pluginService) {
            root.pluginService.savePluginState(root.pluginId, "repos", repos);
        }
        root.setStatus("Loaded " + repos.length + " repositories · " + new Date().toLocaleString(Qt.locale(), Locale.ShortFormat) + (missing.length ? "\nNot found: " + missing.join(", ") : ""));
        root.notifyLauncher();
    }

    function setStatus(msg) {
        if (root.pluginService)
            root.pluginService.savePluginState(root.pluginId, "status", msg);
    }

    property var refreshTimer: Timer {
        interval: Math.max(5, root.refreshMinutes) * 60 * 1000
        running: root.enabled
        repeat: true
        onTriggered: root.refresh()
    }

    // ---- Settings ----
    function updateSettings() {
        if (!root.pluginService)
            return;
        const ps = root.pluginService;
        root.enabled = ps.loadPluginData(root.pluginId, "enabled", true);
        root.trigger = ps.loadPluginData(root.pluginId, "trigger", "gh");
        root.username = (ps.loadPluginData(root.pluginId, "username", "") || "").trim();
        root.tokenVersion = ps.loadPluginData(root.pluginId, "tokenVersion", 0) || 0;
        root.showForks = ps.loadPluginData(root.pluginId, "showForks", true);
        root.showArchived = ps.loadPluginData(root.pluginId, "showArchived", false);
        root.refreshMinutes = parseInt(ps.loadPluginData(root.pluginId, "refreshMinutes", 30)) || 30;
        root.extraRepos = root.normalizeExtraRepos(ps.loadPluginData(root.pluginId, "extraRepos", []));

        // Refetch when the account or the extra repositories change
        const fetchKey = root.username + "|" + root.tokenVersion + "|" + root.extraRepos.join(",");
        if (root.enabled && fetchKey !== root.lastFetchKey) {
            root.lastFetchKey = fetchKey;
            Qt.callLater(root.refresh);
        }
        root.notifyLauncher();
    }

    // Hidden repos and refresh requests live in the plugin *state*, not in the settings:
    // DMS reloads a launcher plugin (and rebuilds its settings page) on every settings save,
    // which would make the settings page jump back to the top on each toggle.
    function updateState() {
        if (!root.pluginService)
            return;
        const ps = root.pluginService;
        const hidden = ps.loadPluginState(root.pluginId, "hiddenRepos", []);
        const list = (hidden && hidden.length !== undefined) ? Array.from(hidden) : [];
        if (JSON.stringify(list) !== JSON.stringify(root.hiddenRepos)) {
            root.hiddenRepos = list;
            root.notifyLauncher();
        }
        const refreshRequest = ps.loadPluginState(root.pluginId, "refreshRequest", 0);
        if (refreshRequest !== root.lastRefreshRequest) {
            const first = root.lastRefreshRequest === 0 && root.cachedRepos.length > 0;
            root.lastRefreshRequest = refreshRequest;
            if (!first)
                Qt.callLater(root.refresh);
        }
    }

    // One-time move of hiddenRepos from the settings (v1.0 before this change) to the state
    function migrateHidden() {
        const ps = root.pluginService;
        const legacy = ps.loadPluginData(root.pluginId, "hiddenRepos", null);
        if (!legacy || legacy.length === undefined || legacy.length === 0)
            return;
        const current = ps.loadPluginState(root.pluginId, "hiddenRepos", []);
        const merged = Array.from(new Set(Array.from(current || []).concat(Array.from(legacy))));
        ps.savePluginState(root.pluginId, "hiddenRepos", merged);
        ps.savePluginData(root.pluginId, "hiddenRepos", []);
    }

    // Accepts "owner/name", "https://github.com/owner/name(.git)" or "github.com/owner/name/...";
    // entries come from ListSettingWithInput as { repo: "..." } objects.
    function normalizeExtraRepos(list) {
        let out = [];
        for (const entry of (list && list.length !== undefined ? Array.from(list) : [])) {
            let v = (typeof entry === "string" ? entry : (entry && entry.repo) || "").trim();
            v = v.replace(/^(https?:\/\/)?(www\.)?github\.com\//i, "").replace(/\.git$/i, "");
            const m = v.match(/^([A-Za-z0-9-]{1,39})\/([A-Za-z0-9._-]{1,100})/);
            if (m && !out.some(o => o.toLowerCase() === (m[1] + "/" + m[2]).toLowerCase()))
                out.push(m[1] + "/" + m[2]);
        }
        return out;
    }

    function init() {
        if (!root.pluginService)
            return;
        const cached = root.pluginService.loadPluginState(root.pluginId, "repos", []);
        root.cachedRepos = (cached && cached.length !== undefined) ? Array.from(cached) : [];
        root.migrateHidden();
        root.updateState();
        root.updateSettings();
    }

    onPluginServiceChanged: root.init()
    Component.onCompleted: root.init()

    property var settingsListener: Connections {
        target: root.pluginService
        function onPluginDataChanged(pluginId) {
            if (pluginId === root.pluginId)
                root.updateSettings();
        }
        function onPluginStateChanged(pluginId) {
            if (pluginId === root.pluginId)
                root.updateState();
        }
    }

    // ---- Launcher ----
    function isVisible(r) {
        if (root.hiddenRepos.includes(r.fullName))
            return false;
        if (r.extra)
            return true; // added by hand: always shown, even if it is a fork or archived
        if (r.fork && !root.showForks)
            return false;
        if (r.archived && !root.showArchived)
            return false;
        return true;
    }

    function getItems(query) {
        if (!root.enabled)
            return [];
        const q = query ? query.trim().toLowerCase() : "";
        const terms = q.split(/\s+/).filter(t => t.length > 0);
        return root.cachedRepos.filter(r => root.isVisible(r) && terms.every(t => (r.fullName + " " + r.description).toLowerCase().includes(t))).map(r => {
            let tags = [];
            if (r.private)
                tags.push("🔒 private");
            if (r.fork)
                tags.push("fork");
            if (r.archived)
                tags.push("archived");
            if (r.extra)
                tags.push("pinned");
            const prefix = tags.length ? "[" + tags.join(", ") + "] " : "";
            const shownName = r.owner && r.owner.toLowerCase() !== root.username.toLowerCase() ? r.fullName : r.name;
            return {
                name: shownName,
                icon: root.githubIcon,
                comment: prefix + (r.description || r.fullName),
                action: "open:" + r.url,
                repoFullName: r.fullName,
                repoUrl: r.url,
                cloneUrl: r.cloneUrl
            };
        });
    }

    function notifyLauncher() {
        root.itemsChanged();
        if (root.pluginService && root.pluginService.requestLauncherUpdate)
            root.pluginService.requestLauncherUpdate(root.pluginId);
    }

    function setRepoHidden(fullName, hidden) {
        if (!fullName)
            return;
        let list = root.hiddenRepos.filter(n => n !== fullName);
        if (hidden)
            list.push(fullName);
        root.hiddenRepos = list;
        if (root.pluginService)
            root.pluginService.savePluginState(root.pluginId, "hiddenRepos", list);
        else
            root.notifyLauncher();
    }

    // Defense in depth: the cached repo list lives on disk, so never hand arbitrary
    // strings to xdg-open / the clipboard, only GitHub URLs.
    function isGithubUrl(url) {
        return typeof url === "string" && /^https:\/\/github\.com\/[A-Za-z0-9._\/-]+$/.test(url);
    }

    function isCloneUrl(url) {
        return typeof url === "string" && (/^git@github\.com:[A-Za-z0-9._\/-]+\.git$/.test(url) || root.isGithubUrl(url));
    }

    function openUrl(url) {
        if (root.isGithubUrl(url))
            Quickshell.execDetached(["xdg-open", url]);
        else
            console.warn("DankGithub: refusing to open non-GitHub URL");
    }

    function copyText(text) {
        if (root.isCloneUrl(text))
            Quickshell.execDetached(["wl-copy", "--", text]);
    }

    function getContextMenuActions(item) {
        if (!item?.repoFullName)
            return [];
        return [
            {
                icon: "visibility_off",
                text: "Hide repository",
                action: () => root.setRepoHidden(item.repoFullName, true)
            },
            {
                icon: "bug_report",
                text: "Open issues",
                closeLauncher: true,
                action: () => root.openUrl(item.repoUrl + "/issues")
            },
            {
                icon: "merge",
                text: "Open pull requests",
                closeLauncher: true,
                action: () => root.openUrl(item.repoUrl + "/pulls")
            },
            {
                icon: "content_copy",
                text: "Copy URL",
                closeLauncher: true,
                action: () => root.copyText(item.repoUrl)
            },
            {
                icon: "terminal",
                text: "Copy clone URL (SSH)",
                closeLauncher: true,
                action: () => root.copyText(item.cloneUrl)
            }
        ];
    }

    function executeItem(item) {
        if (!item?.action)
            return;
        root.openUrl(item.action.replace("open:", ""));
    }
}
