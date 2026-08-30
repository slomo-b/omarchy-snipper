// Snipper — Omarchy-native app that lives entirely in this popup.
//
// Capture is solved NATIVELY in QML (no slurp, whose input is unreliable for
// background processes):
//   "Select area":
//     1. grim takes the whole screen -> ~/.local/state/snipper/full.png
//     2. a full-screen overlay shows the frozen image; drag a box over the
//        area (pointer in our surface = reliable)
//     3. the region is cut from full.png via ImageMagick -> tesseract -> text
//        to the clipboard -> reopen the popup with the result.
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
  // UI language from the system locale (de* -> German, otherwise English = default).
  readonly property string uiLang: String(Qt.locale().name).toLowerCase().indexOf("de") === 0 ? "de" : "en"
  // Tag -> localized string. English is the default; German texts only render
  // for a German locale. "Snip it!" stays identical as the call-to-action in
  // both languages.
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
  /* text = OCR back into characters; image = copy only the image region */
  property string mode: "text"

  // --- State ---
  property var history: []
  property string lastText: ""
  property bool busy: false
  property string busyHint: ""

  // --- Selection overlay state ---
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
  // BarWidget/shell: openFromHotkey is needed so summon/hotkey can open the popup.
  function openFromHotkey() { open() }

  /// Take a full screenshot and show the selection surface.
  function startSnip() {
    console.log("[snipper] startSnip() bar=" + (root.bar !== null))
    root.close()                 // close the popup so the overlay is unobstructed
    root.busy = true
    root.fullPng = root.sdy + "/full.png"
    // Defer the capture to a detached bar.run subprocess: grim does not write a
    // file from a Quickshell-Process context (rc=0 but empty). bar.run children
    // write reliably. READY-marker = screenshot taken.
    if (root.bar && root.bar.run) {
      root.bar.run('umask 077; mkdir -p ' + root.sdy + '; rm -f ' + root.sdy + '/full.png ' + root.sdy + '/full.ready; ' +
                   'grim -t png ' + root.sdy + '/full.png && touch ' + root.sdy + '/full.ready')
      root.busyHint = root.tr("capture")
      capTimer.running = true
      capTimer.restart()
    } else {
      console.log("[snipper] no bar.run available!")
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
          root.selecting = true      // show the full-screen overlay
          capImg.source = "file://" + root.fullPng
          console.log("[snipper] show overlay, fullPng=" + root.fullPng)
        }
      }
    }
  }

  /// Determine the real scale factor (physical/logical) once the full image is loaded.
  function recomputeDpi() {
    if (capImg.status === Image.Ready && selWin.width > 0) {
      root.dpr = capImg.sourceSize.width / selWin.width
      console.log("[snipper] dpr=" + root.dpr)
    }
  }

  /// Cut the selection out of the full image and run OCR.
  function commitSelection() {
    var x0 = Math.min(root.selX0, root.selX1)
    var y0 = Math.min(root.selY0, root.selY1)
    var w = Math.abs(root.selX1 - root.selX0)
    var h = Math.abs(root.selY1 - root.selY0)
    if (!isFinite(w) || !isFinite(h) || w < 4 || h < 4) { root.cancelSelect(); return }

    // Convert logical overlay px -> image px, robust against NaN:
    // factor = image width / window(logical) width. Fallback in case the image
    // is not loaded yet.
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
        'umask 077; cd ' + root.sdy,
        crop + ' 2>>' + root.dbg,
        'wl-copy --type image/png < ocr.png 2>>' + root.dbg,
        'printf "IMG"'
      ].join("; ")
    } else {
      script = [
        'umask 077; cd ' + root.sdy,
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
        root.open()   // reopen the popup
      }
    }
  }

  function acceptResult(text) {
    root.lastText = text
    root.history = [text].concat(root.history).slice(0, 12)
    root.persist()
  }

  // --- Fullscreen selection surface -----------------------------------------
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
      color: "#55000000"   // slightly dimmed; selection stands out
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

  // --- History -----------------------------------------------------------------
  // Least-privilege rule: never pass recognized/pasted screen text to child
  // processes as a command-line argument. Arguments show up in the world-
  // readable /proc/<pid>/cmdline of a child and leak whatever was on screen
  // (often a password, recovery code, or token). Text is instead handed over
  // *stdin* (same pattern Omarchy's network panel uses for secrets). Files it
  // writes are created with umask 077 (owner-only).
  function copyText(t) {
    if (t === "") return
    clipProc.textData = t
    clipProc.command = ["bash", "-c",
      'IFS= read -r -d "" d; printf "%s" "$d" | wl-copy']
    clipProc.running = true
  }
  function clearHistory() {
    root.history = []
    root.persist()
  }
  function persist() {
    var file = Quickshell.env("HOME") + "/.local/state/snipper/history"
    writeCmd.textData = root.history.join("\n")
    writeCmd.command = ["bash", "-c",
      'IFS= read -r -d "" d; umask 077; mkdir -p "$(dirname "$1")"; printf "%s" "$d" > "$1".tmp && mv "$1".tmp "$1"',
      "x", file]
    writeCmd.running = true
  }

  // Text on stdin -> wl-copy (argv-free). NUL delimiter: multi-line OCR text
  // arrives whole without needing EOF, so the read never hangs.
  Process {
    id: clipProc
    property string textData: ""
    stdinEnabled: true
    onStarted: {
      write(textData + "\0")
      textData = ""
    }
  }
  Process {
    id: writeCmd
    property string textData: ""
    stdinEnabled: true
    onStarted: {
      write(textData + "\0")
      textData = ""
    }
  }

  Component.onCompleted: {
    console.log("[snipper] Panel loaded, bar=" + (root.bar !== null))
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
  // Neutralize screen-derived text for AutoText rendering: escape &, <, > so it
  // is never interpreted as rich text/HTML (no markup, no remote resource
  // fetch inside the shell). Order matters: escape & first.
  function plain(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // --- Popup UI ---------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.barIdentity
    open: root.opened
    contentWidth: Style.space(320)
    // No scrolling over the whole popup: height = natural content size
    // (fittedContentHeight). Only result text and history scroll internally.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    Column {
      id: panelColumn
      width: parent.width
      spacing: Style.space(8)

        // ---- Hero row: large cuttermesser icon + title/status left,
        //      mode toggle (Text/Image) right.
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

        // Hairline divider (weather style)
        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.fg
          opacity: 0.12
        }

        // Section label "Detected" (small, letter-spaced, tinted like weather)
        Text {
          text: root.tr("detected").toUpperCase()
          color: Qt.darker(root.fg, 1.5)
          font.family: root.appFont
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
        }

        // Result box: FIXED height + scrollable (cap long OCR text instead of
        // growing the popup -> the bottom-most button always keeps its place).
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
              textFormat: Text.PlainText   // untrusted screen text: never rich text
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

        // History: fixed max height + internally scrollable -> content never runs
        // out of the box. A custom thin track+handle scrollbar on the right that
        // only appears on overflow and never overlaps the text.
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
              // The system Button renders its text with AutoText (the default). Since the
              // history entries come from the screen (attacker-choosable), HTML-
              // escape them here so they can never become rich text (no remote
              // fetch).
              text: root.plain(root.clip(modelData))
              leftAlign: true
              onClicked: root.copyText(modelData)   // copies the ORIGINAL text
            }
          }

          // Track: only on overflow, at the right in its own area.
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
          // Handle: follows the scroll position, never above the text.
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