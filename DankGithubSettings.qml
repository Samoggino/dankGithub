import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "dankGithub"

    StyledText {
        width: parent.width
        text: "GitHub Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "enabled"
        label: "Enable Plugin"
        description: "Show your GitHub repositories in the launcher"
        defaultValue: true
    }

    ToggleSetting {
        id: noTriggerToggle
        settingKey: "noTrigger"
        label: "Always Active (No Trigger)"
        description: value ? "Repositories always appear in the launcher results." : "Use a trigger to list repositories."
        defaultValue: false
        onValueChanged: root.saveValue("trigger", value ? "" : (triggerSetting.value || "gh"))
    }

    StringSetting {
        id: triggerSetting
        visible: !noTriggerToggle.value
        settingKey: "trigger"
        label: "Search Trigger"
        description: "Example: 'gh' → 'gh dotfiles'"
        defaultValue: "gh"
    }

    StringSetting {
        settingKey: "username"
        label: "GitHub Username"
        description: "Used to fetch public repositories when no token is set"
        placeholder: "octocat"
        defaultValue: ""
    }

    // ---- Token (stored encrypted in the system keyring via Secret Service) ----
    property bool hasToken: false
    property string tokenMessage: ""

    function bumpTokenVersion() {
        root.saveValue("tokenVersion", Date.now()); // tells the launcher to refetch
    }

    property var tokenCheck: Process {
        // Only the exit code is used: the secret itself is discarded by the shell
        command: ["sh", "-c", "secret-tool lookup service dankGithub account token >/dev/null 2>&1"]
        onExited: code => root.hasToken = code === 0
    }

    property var tokenStore: Process {
        command: ["secret-tool", "store", "--label=Dank GitHub token", "service", "dankGithub", "account", "token"]
        stdinEnabled: true
        onStarted: {
            write(tokenField.text.trim());
            stdinEnabled = false; // closes stdin so secret-tool saves the value
        }
        onExited: code => {
            tokenField.text = "";
            stdinEnabled = true;
            root.tokenMessage = code === 0 ? "Token saved in the system keyring." : "Could not save the token (is a keyring service running?).";
            if (code === 0) {
                root.hasToken = true;
                root.bumpTokenVersion();
            }
        }
    }

    property var tokenClear: Process {
        command: ["secret-tool", "clear", "service", "dankGithub", "account", "token"]
        onExited: code => {
            root.hasToken = false;
            root.tokenMessage = "Token removed from the keyring.";
            root.bumpTokenVersion();
        }
    }

    function saveToken() {
        if (tokenField.text.trim() && !root.tokenStore.running)
            root.tokenStore.running = true;
    }

    Column {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: "Personal Access Token (optional)"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Theme.fontWeightMedium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: "Needed for private repositories. Create a fine-grained token with read-only \"Metadata\" access on all your repositories (github.com → Settings → Developer settings). It is stored encrypted in the system keyring (GNOME Keyring / KWallet via Secret Service), never in plugin_settings.json. Without a token, a logged-in gh CLI is used if available."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS

            DTextField {
                id: tokenField
                width: parent.width - saveTokenButton.width - clearTokenButton.width - 2 * Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: root.hasToken ? "•••••••• (stored in keyring, type to replace)" : "github_pat_…"
                echoMode: TextInput.Password
                showPasswordToggle: true
                onAccepted: root.saveToken()
            }

            DIconButton {
                id: saveTokenButton
                anchors.verticalCenter: parent.verticalCenter
                variant: "filled"
                iconName: "check"
                tooltipText: "Save token to keyring"
                onClicked: root.saveToken()
            }

            DIconButton {
                id: clearTokenButton
                anchors.verticalCenter: parent.verticalCenter
                iconName: "delete"
                tooltipText: "Remove token from keyring"
                enabled: root.hasToken
                onClicked: root.tokenClear.running = true
            }
        }

        StyledText {
            width: parent.width
            visible: text !== ""
            text: root.tokenMessage || (root.hasToken ? "A token is stored in the system keyring." : "")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.primary
            wrapMode: Text.WordWrap
        }
    }

    ToggleSetting {
        settingKey: "showForks"
        label: "Show Forks"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showArchived"
        label: "Show Archived Repositories"
        defaultValue: false
    }

    StringSetting {
        settingKey: "refreshMinutes"
        label: "Refresh Interval (minutes)"
        description: "How often the repository list is re-downloaded (minimum 5)"
        defaultValue: "30"
    }

    // ---- Extra public repositories ----
    ListSettingWithInput {
        settingKey: "extraRepos"
        label: "Extra Repositories"
        description: "Public repositories from other users or organizations to show in the launcher. Use owner/name or paste the GitHub URL. They are always shown (even forks or archived ones) and tagged as \"pinned\"."
        defaultValue: []
        fields: [
            {
                id: "repo",
                label: "Repository",
                placeholder: "owner/name or https://github.com/owner/name",
                width: 360,
                required: true
            }
        ]
    }

    // ---- Repository visibility ----
    // Order is computed only when the repository list itself changes (or the page opens):
    // shown repositories first, hidden ones at the bottom, alphabetical within each group.
    // Toggling a repository does not reorder or rebuild the rows, so the page doesn't scroll.
    property var repos: []
    property string reposKey: ""
    property var hiddenRepos: []
    property string status: ""

    function loadState() {
        const ps = root.pluginService;
        if (!ps)
            return;
        const h = ps.loadPluginState("dankGithub", "hiddenRepos", []); // state, not settings: see DankGithub.qml
        root.hiddenRepos = (h && h.length !== undefined) ? Array.from(h) : [];
        root.status = ps.loadPluginState("dankGithub", "status", "");

        const r = ps.loadPluginState("dankGithub", "repos", []);
        const list = (r && r.length !== undefined) ? Array.from(r) : [];
        const key = JSON.stringify(list.map(x => [x.fullName, x.description, x.private, x.fork, x.archived]));
        if (key === root.reposKey)
            return;
        root.reposKey = key;
        root.repos = list.sort((a, b) => {
            const ha = root.hiddenRepos.includes(a.fullName), hb = root.hiddenRepos.includes(b.fullName);
            return ha !== hb ? (ha ? 1 : -1) : a.fullName.localeCompare(b.fullName);
        });
    }

    function setHidden(fullName, hidden) {
        let list = root.hiddenRepos.filter(n => n !== fullName);
        if (hidden)
            list.push(fullName);
        root.hiddenRepos = list;
        root.pluginService?.savePluginState("dankGithub", "hiddenRepos", list);
    }

    property var stateListener: Connections {
        target: root.pluginService
        function onPluginStateChanged(pluginId) {
            if (pluginId === "dankGithub")
                root.loadState();
        }
        function onPluginDataChanged(pluginId) {
            if (pluginId === "dankGithub")
                root.loadState();
        }
    }

    // DMS assigns pluginService after the page is created: load the list as soon as it arrives
    onPluginServiceChanged: if (root.pluginService) Qt.callLater(root.loadState)

    Component.onCompleted: {
        Qt.callLater(root.loadState);
        root.tokenCheck.running = true;
    }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        Row {
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                width: parent.width - refreshButton.width - Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                text: "Repositories"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            DIconButton {
                id: refreshButton
                anchors.verticalCenter: parent.verticalCenter
                iconName: "refresh"
                tooltipText: "Refresh now"
                onClicked: root.pluginService?.savePluginState("dankGithub", "refreshRequest", Date.now())
            }
        }

        StyledText {
            width: parent.width
            text: (root.status ? root.status + "\n" : "") + (root.repos.length === 0 ? "No repositories loaded yet." : "Turn off a repository to hide it from the launcher (also possible from the launcher's context menu).")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: root.repos

            Row {
                id: repoRow
                required property var modelData
                width: parent.width
                spacing: Theme.spacingM

                Column {
                    width: parent.width - repoToggle.width - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    StyledText {
                        width: parent.width
                        text: (repoRow.modelData.private ? "🔒 " : "") + repoRow.modelData.fullName + (repoRow.modelData.fork ? "  · fork" : "") + (repoRow.modelData.archived ? "  · archived" : "")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Theme.fontWeightMedium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width
                        visible: text !== ""
                        text: repoRow.modelData.description || ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }

                DToggle {
                    id: repoToggle
                    anchors.verticalCenter: parent.verticalCenter
                    checked: !root.hiddenRepos.includes(repoRow.modelData.fullName)
                    onToggled: isChecked => root.setHidden(repoRow.modelData.fullName, !isChecked)
                }
            }
        }
    }
}
