import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar indicator for favorite football teams: shows the next kickoff or a
// live score, and opens a popup with the recent event feed (goals, cards,
// substitutions) plus upcoming fixtures. All data comes from state.json,
// written by bin/poll.sh — this widget never talks to the network itself.
BarWidget {
  id: root
  moduleName: "io.github.bekkenes.football-tracker"

  property var state: ({})
  property var config: ({})
  property bool popupOpen: false
  property bool settingsOpen: false
  property string saveStatus: ""
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.bekkenes.football-tracker/"
  readonly property bool hasApiKey: config.has_api_key === true
  readonly property var configuredTeams: config.teams || []

  function close() { popupOpen = false }

  readonly property string label: Model.barLabel(state)
  readonly property var liveMatch: state.live_match || null
  readonly property var nextMatch: state.next_match || null
  readonly property var recentEvents: state.recent_events || []
  readonly property var upcoming: state.upcoming || []

  visible: label !== ""
  implicitWidth: label !== "" ? row.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy-football-tracker/state.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.state = Model.safeParse(text())
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy-football-tracker/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.config = Model.safeParse(text())
    onFileChanged: reload()
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Item {
      id: glyphFrame
      anchors.verticalCenter: parent.verticalCenter
      width: Style.font.body
      height: Style.font.body

      Image {
        id: glyph
        anchors.fill: parent
        source: root.liveMatch ? Qt.resolvedUrl("icons/goal.svg") : Qt.resolvedUrl("icons/ball.svg")
        sourceSize.width: width
        sourceSize.height: height
        // ball.svg ships a fixed near-white stroke (#e5e7eb) that doesn't
        // adapt to the bar's theme — tint it to match the label text. goal.svg
        // keeps its own deliberate green (it's a status color, not neutral).
        visible: !!root.liveMatch
        layer.enabled: !root.liveMatch
      }

      MultiEffect {
        anchors.fill: glyph
        source: glyph
        visible: !root.liveMatch
        colorization: 1.0
        colorizationColor: root.bar ? root.bar.barForeground : Color.bar.text
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      visible: !root.vertical
      color: root.bar ? root.bar.barForeground : Color.bar.text
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.popupOpen = !root.popupOpen
    onEntered: if (root.bar) root.bar.showTooltip(root, root.label)
    onExited: if (root.bar) root.bar.hideTooltip(root)
    hoverEnabled: true
  }

  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      // --- live match ---
      Column {
        visible: root.liveMatch !== null
        width: parent.width
        spacing: Style.space(4)

        Text {
          textFormat: Text.PlainText
          text: root.liveMatch ? (root.liveMatch.team + " " + root.liveMatch.team_score + " - " + root.liveMatch.opponent_score + " " + root.liveMatch.opponent) : ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          width: parent.width
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          text: root.liveMatch ? (root.liveMatch.competition + " · " + (root.liveMatch.elapsed || 0) + "'") : ""
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator {
        visible: root.liveMatch !== null && root.recentEvents.length > 0
        foreground: root.bar.foreground
      }

      // --- recent events, as cards ---
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.recentEvents.length > 0

        Repeater {
          model: root.recentEvents.slice(0, 8)

          Rectangle {
            id: card
            required property var modelData
            width: parent.width
            height: cardRow.implicitHeight + Style.space(12)
            radius: Style.space(6)
            color: Qt.darker(root.bar.background, 1.05)
            border.width: 0

            Rectangle {
              id: stripe
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(3)
              radius: 1
              color: card.modelData.type === "Goal" ? "#22c55e"
                : (card.modelData.type === "Card" ? (card.modelData.detail && card.modelData.detail.indexOf("Red") >= 0 ? "#ef4444" : "#eab308")
                : "#3b82f6")
            }

            Row {
              id: cardRow
              anchors.left: stripe.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Image {
                anchors.verticalCenter: parent.verticalCenter
                source: Qt.resolvedUrl("icons/" + card.modelData.icon)
                width: Style.space(18)
                height: Style.space(18)
                sourceSize.width: width
                sourceSize.height: height
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  text: Model.eventHeadline(card.modelData) + " — " + card.modelData.team
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: card.modelData.minute + "' " + card.modelData.player
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }

      PanelSeparator {
        visible: root.liveMatch === null && root.upcoming.length > 0
        foreground: root.bar.foreground
      }

      // --- upcoming fixtures (shown when nothing is live) ---
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.liveMatch === null

        Text {
          textFormat: Text.PlainText
          text: "Upcoming"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Repeater {
          model: root.upcoming.slice(0, 5)

          Column {
            required property var modelData
            width: parent.width
            spacing: 0

            Text {
              textFormat: Text.PlainText
              text: modelData.team + " vs " + modelData.opponent
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              width: parent.width
              elide: Text.ElideRight
            }
            Text {
              textFormat: Text.PlainText
              text: Model.dayLabel(modelData.kickoff) + Model.kickoffClock(modelData.kickoff) + " · " + modelData.competition
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }
        }

        Text {
          visible: root.upcoming.length === 0
          textFormat: Text.PlainText
          text: "No upcoming fixtures cached yet."
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      Button {
        text: root.settingsOpen ? "Hide settings" : "Settings"
        foreground: root.bar.foreground
        onClicked: {
          root.settingsOpen = !root.settingsOpen
          if (root.settingsOpen) {
            teamsField.text = root.configuredTeams.map(function(t) { return t.name }).join(", ")
            apiKeyField.text = ""
            root.saveStatus = ""
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.settingsOpen

        Text {
          textFormat: Text.PlainText
          text: root.hasApiKey ? "API key: set" : "API key: not set"
          color: root.hasApiKey ? "#22c55e" : Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          textFormat: Text.RichText
          text: "Free key: <a href=\"https://dashboard.api-football.com/register\">dashboard.api-football.com/register</a>"
          color: Qt.darker(root.bar.foreground, 1.3)
          linkColor: Color.accent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          onLinkActivated: function(link) { Qt.openUrlExternally(link) }
        }

        TextField {
          id: apiKeyField
          width: parent.width
          password: true
          placeholderText: root.hasApiKey ? "Leave blank to keep current key" : "Paste your API-Football key"
        }

        Text {
          textFormat: Text.PlainText
          text: "Favorite teams (comma-separated — editing this list adds/removes teams)"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          wrapMode: Text.WordWrap
        }

        TextField {
          id: teamsField
          width: parent.width
          placeholderText: "e.g. Liverpool, Rosenborg"
        }

        Text {
          textFormat: Text.PlainText
          text: "Live score polling"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          text: "Auto spreads today's live-match minutes across a ~100/day API"
            + " budget automatically. Manual always uses the interval you pick,"
            + " even if that risks running out of requests."
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          wrapMode: Text.WordWrap
        }

        Dropdown {
          id: livePollModeDropdown
          width: parent.width
          value: root.config.live_poll_mode || "auto"
          options: [
            { value: "auto", label: "Auto (recommended)" },
            { value: "manual", label: "Manual interval" }
          ]
          foreground: root.bar.foreground
          onChanged: function(v) {
            if (root.bar) root.bar.run("bash " + root.pluginDir + "bin/save-settings.sh --live-poll-mode " + Model.shQuote(v))
          }
        }

        Dropdown {
          id: livePollIntervalDropdown
          width: parent.width
          visible: livePollModeDropdown.value === "manual"
          value: String(root.config.poll_interval_live_seconds || 180)
          options: [
            { value: "60", label: "Every 1 min" },
            { value: "120", label: "Every 2 min" },
            { value: "180", label: "Every 3 min" },
            { value: "300", label: "Every 5 min" },
            { value: "600", label: "Every 10 min" }
          ]
          foreground: root.bar.foreground
          onChanged: function(v) {
            if (root.bar) root.bar.run("bash " + root.pluginDir + "bin/save-settings.sh --live-poll-interval " + Model.shQuote(v))
          }
        }

        Row {
          spacing: Style.space(8)

          Button {
            text: "Save"
            foreground: root.bar.foreground
            onClicked: {
              if (root.bar) {
                var cmd = "bash " + root.pluginDir + "bin/save-settings.sh --api-key "
                  + Model.shQuote(apiKeyField.text) + " --teams " + Model.shQuote(teamsField.text)
                root.bar.run(cmd)
              }
              apiKeyField.text = ""
              root.saveStatus = "Saved — check notifications for team matches."
            }
          }

          Button {
            text: "Search teams (terminal)"
            foreground: root.bar.foreground
            onClicked: {
              if (root.bar) root.bar.run("omarchy-launch-or-focus-tui --app-id=io.github.bekkenes.football-tracker.setup " + root.pluginDir + "bin/setup.sh")
              root.popupOpen = false
            }
          }
        }

        Text {
          visible: root.saveStatus !== ""
          textFormat: Text.PlainText
          text: root.saveStatus
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
