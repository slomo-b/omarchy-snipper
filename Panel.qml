// Snipper — Omarchy-native App, die KOMPLETT in diesem Popup lebt.
//
// Capture wird NATIV in QML geloest (kein slurp, dessen Input bei Hintergrund-
// Prozessen unzuverlaessig ist):
//   "Bereich auswaehlen":
//     1. grim nimmt den kompletten Screen -> ~/.local/state/snipper/full.png
//     2. eigenes Vollbild-Overlay zeigt das eingefrorene Bild, per Maus-Drag
//        einen Bereich ziehen (Pointer in unserem Surface = zuverlaessig)
//     3. Region via ImageMagick aus full.png schneiden -> tesseract -> Text in
//        Zwischenablage -> Popup mit Ergebnis wieder oeffnen.
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.slomo-b.snipper"
  ipcTarget: "io.github.slomo-b.snipper"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string label: "Snip"
  // UI-Sprache nach System-Locale (de* -> Deutsch, sonst Englisch = Standard).
  readonly property string uiLang: String(Qt.locale().name).toLowerCase().indexOf("de") === 0 ? "de" : "en"
  // Schluessel -> Lokalisierung. Die App ist standardmaessig Englisch; nur bei
  // deutscher Locale werden deutsche Texte angezeigt. "Snip it!" bleibt als
  // Call-to-Action in beiden Sprachen identisch.
  function tr(tag) {
    var en = {
      ready: "Ready",
      working: "Working\u2026",
      capture: "Capturing\u2026",
      snip: "Snip it!",
      extractText: "Extract text",
      extractImg: "Extract image",
      copyText: "Copy text",
      detected: "Detected",
      emptyResult: "No area selected yet.",
      history: "History",
      clearHistory: "Clear history",
      noHistory: "No history",
      imgCopied: "Image in clipboard",
      txtCopied: "Text detected \u2014 in clipboard",
      cancelled: "Selection cancelled / no text detected",
      imgExtracted: "Image extracted \u2014 in clipboard"
    }
    var de = {
      ready: "Bereit",
      working: "Warten\u2026",
      capture: "Aufnahme\u2026",
      snip: "Snip it!",
      extractText: "Text extrahieren",
      extractImg: "Bild extrahieren",
      copyText: "Text kopieren",
      detected: "Erkannt",
      emptyResult: "Noch kein Bereich ausgew\u00e4hlt.",
      history: "Verlauf",
      clearHistory: "Verlauf leeren",
      noHistory: "Kein Verlauf",
      imgCopied: "Bild in Zwischenablage",
      txtCopied: "Text erkannt \u2014 in Zwischenablage",
      cancelled: "Bereich abgebrochen / kein Text erkannt",
      imgExtracted: "Bild extrahiert \u2014 in Zwischenablage"
    }
    return ((root.uiLang === "de") ? de : en)[tag] || tag
  }
  readonly property color fg: root.bar && root.bar.foreground ? root.bar.foreground : Color.foreground
  readonly property string appFont: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
  property string lang: "eng"
  /* text = OCR zurueck in Zeichen; image = nur den Bildbereich kopieren */
  property string mode: "text"

  // --- Zustand ---
  property var history: []
  property string lastText: ""
  property bool busy: false
  property string busyHint: ""

  // --- Auswahl-Overlay-Zustand ---
  property bool selecting: false
  property string fullPng: ""
  property real dpi: 1
  property real selX0: 0
  property real selY0: 0
  property real selX1: 0
  property real selY1: 0
  property bool dragging: false

  readonly property string dbg: Quickshell.env("HOME") + "/.local/state/snipper/debug.log"
  readonly property string sdy: Quickshell.env("HOME") + "/.local/state/snipper"

  function refresh() {}
  // BarWidget/shell: openFromHotkey noetig, damit summon/hotkey das Popup oeffnet.
  function openFromHotkey() { open() }

  /// Voll-Screenshot aufnehmen und die Auswahl-Oberflaeche zeigen.
  function startSnip() {
    console.log("[snipper] startSnip() bar=" + (root.bar !== null))
    root.close()                 // Popup zu, damit der Overlay frei liegt
    root.busy = true
    root.fullPng = root.sdy + "/full.png"
    // Capture NACH bar.run (detached) verlagern: grim schreibt aus dem
    // Quickshell-Process-Kontext keine Datei (rc=0 aber leer). bar.run-Sub-
    // prozesse schreiben bekanntermassen zuverlaessig. READY-Marker = fertig.
    if (root.bar && root.bar.run) {
      root.bar.run('mkdir -p ' + root.sdy + '; rm -f ' + root.sdy + '/full.png ' + root.sdy + '/full.ready; ' +
                   'grim -t png ' + root.sdy + '/full.png && touch ' + root.sdy + '/full.ready')
      root.busyHint = root.tr("capture")
      capTimer.running = true
      capTimer.restart()
    } else {
      console.log("[snipper] kein bar.run!")
      root.busy = false
    }
  }

  Timer {
    id: capTimer
    interval: 350
    repeat: true
    onTriggered: root.checkCaptureReady()
  }

  function checkCaptureReady() {
    pollProc.command = ["bash", "-c", "test -f " + root.sdy + "/full.ready && echo READY"]
    pollProc.running = false
    pollProc.running = true
  }
  Process {
    id: pollProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").indexOf("READY") >= 0) {
          capTimer.running = false
          root.busy = false
          root.selecting = true      // Vollbild-Overlay anzeigen
          capImg.source = "file://" + root.fullPng
          console.log("[snipper] overlay zeigen, fullPng=" + root.fullPng)
        }
      }
    }
  }

  /// Beim geladenen Vollbild den echten Scale-Faktor bestimmen (physical/logical).
  function recomputeDpi() {
    if (capImg.status === Image.Ready && selWin.width > 0) {
      root.dpr = capImg.sourceSize.width / selWin.width
      console.log("[snipper] dpr=" + root.dpr)
    }
  }

  /// Laesst die Auswahl in das Vollbild schneiden + OCR laufen.
  function commitSelection() {
    var x0 = Math.min(root.selX0, root.selX1)
    var y0 = Math.min(root.selY0, root.selY1)
    var w = Math.abs(root.selX1 - root.selX0)
    var h = Math.abs(root.selY1 - root.selY0)
    if (!isFinite(w) || !isFinite(h) || w < 4 || h < 4) { root.cancelSelect(); return }

    // Umrechnung logical Overlay-Px -> Bild-Px, robust gegen NaN:
    // Faktor = Bildbreite / Fenster(logisch)-breite. Fallback, falls das Bild
    // noch nicht geladen ist.
    var sx = (capImg.sourceSize && capImg.sourceSize.width > 0) ? capImg.sourceSize.width : 1920
    var sy = (capImg.sourceSize && capImg.sourceSize.height > 0) ? capImg.sourceSize.height : 1080
    var sw = selWin.width > 0 ? selWin.width : 1
    var dpx = sx / sw
    if (isNaN(dpx) || !isFinite(dpx) || dpx <= 0) dpx = 1

    var gx = Math.max(0, Math.round(x0 * dpx))
    var gy = Math.max(0, Math.round(y0 * dpx))
    var gw = Math.max(1, Math.round(w * dpx))
    var gh = Math.max(1, Math.round(h * dpx))
    gw = Math.min(gw, sx - gx)
    gh = Math.min(gh, sy - gy)
    console.log("[snipper] dpx=" + dpx + " crop " + gx + "," + gy + " " + gw + "x" + gh)

    root.selecting = false
    root.busy = true
    var crop = 'convert full.png -crop ' + gw + 'x' + gh + '+' + gx + '+' + gy + ' +repage ocr.png'
    var script
    if (root.mode === "image") {
      script = [
        'cd ' + root.sdy,
        crop + ' 2>>' + root.dbg,
        'wl-copy --type image/png < ocr.png 2>>' + root.dbg,
        'printf "IMG"'
      ].join("; ")
    } else {
      script = [
        'cd ' + root.sdy,
        crop + ' 2>>' + root.dbg,
        't="$(tesseract ocr.png stdout -l ' + root.lang + ' 2>>' + root.dbg + ')"',
        'if [ -n "$t" ]; then printf "%s" "$t" | wl-copy; else wl-copy --type image/png < ocr.png; fi',
        'printf "%s\\n" "$t"'
      ].join("; ")
    }
    ocrProc.command = ["bash", "-c", script]
    ocrProc.running = false
    ocrProc.running = true
  }

  function cancelSelect() {
    root.selecting = false
    root.busy = false
  }

  Process {
    id: ocrProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.busy) return
        root.busy = false
        var raw = String(text || "").trim()
        console.log("[snipper] onStreamFinished len=" + raw.length)
        if (root.mode === "image") {
          root.lastText = root.tr("imgExtracted")
          root.notify(root.tr("imgCopied"))
        } else if (!raw) {
          root.lastText = ""
          root.notify(root.tr("cancelled"))
        } else {
          root.acceptResult(raw)
          root.notify(root.tr("txtCopied"))
        }
        root.open()   // Popup wieder zeigen
      }
    }
  }

  function acceptResult(text) {
    root.lastText = text
    root.history = [text].concat(root.history).slice(0, 12)
    root.persist()
  }

  // --- Vollbild-Auswahl-Surface -------------------------------------------
  PanelWindow {
    id: selWin
    visible: root.selecting
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "snipper-select"
    WlrLayershell.layer: WlrLayer.Overlay

    Image {
      id: capImg
      anchors.fill: parent
      fillMode: Image.Stretch
      onStatusChanged: if (status === Image.Ready) root.recomputeDpi()
    }
    Rectangle {
      anchors.fill: parent
      color: "#55000000"   // leicht abgedunkelt; Auswahl sticht heraus
    }
    MouseArea {
      id: selMouse
      anchors.fill: parent
      cursorShape: Qt.CrossCursor
      onPressed: function(m) {
        root.selX0 = m.x; root.selY0 = m.y; root.selX1 = m.x; root.selY1 = m.y
        root.dragging = true
      }
      onPositionChanged: function(m) {
        if (root.dragging) { root.selX1 = m.x; root.selY1 = m.y }
      }
      onReleased: function(m) {
        if (root.dragging) {
          root.selX1 = m.x; root.selY1 = m.y
          root.dragging = false
          root.commitSelection()
        }
      }
    }
    Rectangle {
      visible: root.dragging
      x: Math.min(root.selX0, root.selX1)
      y: Math.min(root.selY0, root.selY1)
      width: Math.abs(root.selX1 - root.selX0)
      height: Math.abs(root.selY1 - root.selY0)
      color: "transparent"
      border.color: "#5b8cff"
      border.width: 2
    }
  }

  // --- Verlauf -----------------------------------------------------------------
  function copyText(t) {
    if (root.bar && root.bar.run) root.bar.run("omarchy-clipboard-paste-text --copy-only " + shellQuote(t))
  }
  function clearHistory() {
    root.history = []
    root.persist()
  }
  function persist() {
    var file = Quickshell.env("HOME") + "/.local/state/snipper/history"
    writeCmd.command = ["bash", "-c",
        'mkdir -p "$(dirname "$1")" && printf "%s\\n" "${@:2}" > "$1".tmp && mv "$1".tmp "$1"',
        "x", file ].concat(root.history)
    writeCmd.running = true
  }
  Process { id: writeCmd }

  Component.onCompleted: {
    console.log("[snipper] Panel geladen, bar=" + (root.bar !== null))
    loadCmd.command = ["bash", "-c",
      'test -f "$HOME/.local/state/snipper/history" && tail -n 12 "$HOME/.local/state/snipper/history"']
    loadCmd.running = true
  }
  Process {
    id: loadCmd
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.history = String(text || "").split("\n").filter(function(l) { return l.trim() !== "" })
      }
    }
  }

  function notify(msg) {
    if (root.bar && root.bar.run) root.bar.run("omarchy-notification-send " + shellQuote(msg))
  }
  function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
  function clip(t) { return t.length > 44 ? t.slice(0, 41) + "\u2026" : t }

  // --- Popup-UI -------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.barIdentity
    open: root.opened
    contentWidth: Style.space(320)
    // Kein Scrollen auf dem ganzen Popup: Hoehe = natuerliche Inhaltsgroesse
    // (fittedContentHeight). Nur Ergebnis-Text und History scrollen intern.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    Column {
      id: panelColumn
      width: parent.width
      spacing: Style.space(8)

        // ---- Hero-Zeile: grosses Cuttermesser-Icon + Titel/Status links,
        //      Modus-Umschalter (Text/Bild) rechts.
        Item {
          width: parent.width
          height: Math.max(heroLeft.height, modeToggle.height)

          Row {
            id: heroLeft
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(16)

            Item {
              id: heroCutterSlot
              width: Style.space(30)
              height: Style.space(30)
              Image {
                id: heroCutter
                anchors.centerIn: parent
                width: parent.width
                height: parent.height
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                sourceSize.height: Math.round(height * Screen.devicePixelRatio)
                source: "assets/cutter-knife.svg"
                visible: false
                layer.enabled: true
              }
              MultiEffect {
                anchors.fill: heroCutter
                source: heroCutter
                colorization: 1.0
                colorizationColor: root.fg
              }
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                text: "Snipper"
                color: root.fg
                font.family: root.appFont
                font.pixelSize: 18
                font.bold: true
              }
              Text {
                text: root.busy ? (root.busyHint !== "" ? root.busyHint : "OCR\u2026") : root.tr("ready")
                color: Qt.darker(root.fg, 1.5)
                font.family: root.appFont
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }
          }

          Row {
            id: modeToggle
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            Button {
              iconText: "\uf15c"                 // Nerd-Font: file-text-o
              tooltipText: root.tr("extractText")
              selected: root.mode === "text"
              focusable: true
              onClicked: root.mode = "text"
            }
            Button {
              iconText: "\uf03e"                 // Nerd-Font: picture-o
              tooltipText: root.tr("extractImg")
              selected: root.mode === "image"
              focusable: true
              onClicked: root.mode = "image"
            }
          }
        }

        Button {
          width: parent.width
          text: root.busy ? root.tr("working") : root.tr("snip")
          enabled: !root.busy
          focusable: true
          onClicked: root.startSnip()
        }

        // Haarlinien-Trenner (Wetter-Stil)
        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.fg
          opacity: 0.12
        }

        // Sektions-Label "Detected" (klein, gesperrt, getoent wie Wetter)
        Text {
          text: root.tr("detected").toUpperCase()
          color: Qt.darker(root.fg, 1.5)
          font.family: root.appFont
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
        }

        // Ergebnis-Feld: FESTE Hoehe + scrollbar (langen OCR-Text kappen statt das
        // Popup zu verlaengern -> der unterste Button behaelt immer seinen Platz).
        Rectangle {
          id: resultBox
          width: parent.width
          height: Style.space(64)
          radius: Style.cornerRadius
          color: "transparent"
          border.color: Qt.darker(root.fg, 2.2)
          border.width: 1
          ScrollView {
            id: resultScroll
            anchors.fill: parent
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy: resultText.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            Text {
              id: resultText
              width: resultScroll.availableWidth
              text: root.busy ? "\u2026" : (root.lastText !== "" ? root.lastText : root.tr("emptyResult"))
              color: root.fg
              font.family: root.appFont
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              padding: Style.space(6)
            }
          }
        }

        Button {
          width: parent.width
          text: root.tr("copyText")
          enabled: root.lastText !== ""
          focusable: true
          onClicked: root.lastText !== "" && root.copyText(root.lastText)
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.fg
          opacity: 0.12
        }

        Text {
          text: root.tr("history").toUpperCase() + " (" + root.history.length + ")"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.appFont
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
        }

        // History: feste Maximalhoehe + intern scrollbar -> der Inhalt laeuft
        // nie aus der Box. Eigene schmale Track+Handle-Scrollbar rechts, die
        // nur bei Ueberlauf erscheint und NICHT ueber den Text liegt.
        Item {
          width: parent.width
          height: root.history.length > 0 ? Style.space(104) : 0
          visible: root.history.length > 0
          clip: true

          ListView {
            id: historyList
            anchors.fill: parent
            anchors.rightMargin: Style.space(6)
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds
            model: root.history
            delegate: Button {
              width: historyList.width
              text: root.clip(modelData)
              leftAlign: true
              onClicked: root.copyText(modelData)
            }
          }

          // Track: nur bei Ueberlauf, rechts im eigenen Bereich.
          Rectangle {
            id: histTrack
            visible: historyList.contentHeight > historyList.height
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            width: Style.space(3)
            radius: Style.space(2)
            color: Qt.darker(root.fg, 2.2)
          }
          // Handle: folgt der Scroll-Position, nie ueber dem Text.
          Rectangle {
            id: histHandle
            visible: historyList.contentHeight > historyList.height
            anchors.right: parent.right
            width: Style.space(3)
            radius: Style.space(2)
            color: Qt.darker(root.fg, 1.5)
            height: Math.max(Style.space(14), historyList.height * (historyList.height / Math.max(1, historyList.contentHeight)))
            y: historyList.visibleArea.yPosition * (historyList.height - height)
          }
        }

        Button {
          width: parent.width
          text: root.history.length ? root.tr("clearHistory") : root.tr("noHistory")
          enabled: root.history.length > 0
          focusable: true
          onClicked: root.clearHistory()
        }
      }
}
}