The Desktop Environment Manager (DE Manager) for Debian is a useful tool, especially for users who like to experiment with different DE (GNOME, KDE, XFCE, LXQt, MATE, Cinnamon, etc.) or want a "clean" change without remnants of the previous environment.

The purpose of the project
Create a convenient tool (script/application) that:

- Shows the list of available DE. (implemented)
- Sets the selected DE. (implemented)
- Completely removes the selected DE (including dependencies, configs, and residual packages). (implemented)
-Allows you to switch between DE with the previous one cleared.
- Saves user settings (if necessary) before deleting. (implemented)

1. Language and platform
Bash + dialog/whiptail — (implemented).
Python + Tkinter/PyQt — if you want a GUI and more flexibility. (not implemented)

2. System Tools
apt is the main Debian package manager.
apt-cache search, dpkg-query, apt list --installed — for searching and checking packages.
apt autoremove --purge — to remove packages and dependencies.
deborphan — finds "orphaned" packages (optional, but useful).
dialog or whiptail — for the TUI interface (selection of menu items).
update-alternatives — if you need to switch login managers (gdm3, sddm, lightdm, etc.)
