<p align="center">
  <img src="docs/images/banner-dark.png" alt="Toss. Press two keys. Your iPad right in the chat." width="792">
</p>

Toss is a Mac menu-bar app that drops a screenshot of your iPad into the ChatGPT, Codex or Claude chat you have open. It only adds the picture to your draft; you still press Send.

### Press two keys. Your iPad right in the chat.

<p align="center">
  <img src="docs/images/demo-shortcut-dark.gif" alt="Left and right Option add the iPad screenshot to ChatGPT; left and right Shift add it to Claude." width="792">
</p>

### Works wherever the chat window is

The chat does not have to be in front. Press the shortcut while you are reading a past paper or anything else, and Toss brings the right window forward, attaches the screenshot and leaves you in the chat.

### Wired or wireless, your call

The same two keys work either way. Plug the iPad in and Toss uses the cable; unplug it and Toss goes back to Wi‑Fi on its own. The menu-bar icon shows which one is in use.

## Shortcuts

| Press together | Goes to |
| --- | --- |
| Left <kbd>⌥ Option</kbd> + right <kbd>⌥ Option</kbd> | ChatGPT / Codex |
| Left <kbd>⇧ Shift</kbd> + right <kbd>⇧ Shift</kbd> | Claude |

Toss brings the right chat window forward first, then captures and attaches. Works over USB or Wi‑Fi, whichever is connected.

Since 1.0.4, you can also add an iPad screenshot to ChatGPT’s Dot. Open Dot and press both Option keys together; the screenshot stays in the draft until you send it.

## Get started

1. Download the latest [release](https://github.com/ashzene/Toss/releases/latest), open the disk image, and double-click **Toss Installer**. In its window, drag Toss into Applications; Toss installs and opens its setup guide automatically.
2. Connect your iPad with a USB data cable the first time, tap **Trust** and turn on **Developer Mode**. Toss guides you through it.
3. After that, pairing is done. Toss reconnects by itself.

Until an iPad is paired, opening Toss from the Dock or clicking its menu-bar icon brings the setup guide back, even if you closed it earlier.

Needs an Apple silicon Mac with macOS 14+, and an iPad with iPadOS 17+ (17.4+ for USB).

## License

[MIT](LICENSE), except the capture service in [`Backend/`](Backend), which builds on [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) and is [GPL-3.0](Backend/LICENSE).
