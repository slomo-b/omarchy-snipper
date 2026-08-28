// Snipper — Omarchy bar pill. Mirrors the first-party weather bar-widget:
// renders an icon/pill in the bar, and clicking it toggles a WLAN-style
// popup (Panel.qml, a KeyboardPanel anchored to this button).
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.slomo-b.snipper"

  // Hand the panel the bit of shell context it needs to position itself
  // under the button and to run commands via the bar.
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root). Same as the weather
  // widget: navigating with the keyboard/hotkey reveals the popup without the
  // center hover reveal.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: panelLoader.item && panelLoader.item.label !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    // Cuttermesser als getoentes SVG statt Nerd-Font-Glyph. Das SVG ist WEISS
    // gefuellt (wie symbolische Tray-Icons); per Image+MultiEffect wird es auf
    // die Bar-Vordergrundfarbe getoent (foreground / activeColor). Der kleinere
    // kleinere Icon als die opticalCanvas ~0.50 sorgt fuer optisches Padding/Groesse.
    iconComponent: Component {
      Item {
        width: parent.width * 0.34
        height: parent.height * 0.34
        anchors.centerIn: parent
        Image {
          id: cutterImg
          anchors.fill: parent
          fillMode: Image.PreserveAspectFit
          sourceSize.width: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
          sourceSize.height: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
          source: "assets/cutter-knife.svg"
          visible: false
          layer.enabled: true
        }
        MultiEffect {
          anchors.fill: cutterImg
          source: cutterImg
          colorization: 1.0
          colorizationColor: button.active && button.useActiveColor ? button.activeColor : button.foreground
        }
      }
    }
    slotSize: Style.bar.statusSlot
    tooltipText: "Snipper"

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.bar.run("snipper")
      else root.togglePanel()
    }
  }
}