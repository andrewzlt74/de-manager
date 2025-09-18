#!/bin/bash
# ============================================================================
# 🖥️ DE Manager для Debian — Управление окружениями и внешним видом
# Версия 1.3 — Безопасное удаление, фильтр по установленным DE
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/configs"
THEME_CONFIG_DIR="$SCRIPT_DIR/themes/configs"
BACKUP_DIR="$SCRIPT_DIR/backups"
LOG_FILE="$SCRIPT_DIR/logs/de-manager.log"
THEME_BACKUP_DIR="$BACKUP_DIR/themes"
mkdir -p "$BACKUP_DIR" "$SCRIPT_DIR/logs" "$THEME_BACKUP_DIR" "$SCRIPT_DIR/themes/cache"

# -----------------------------------------------------------------------------
# 🧰 Вспомогательные функции
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        dialog --msgbox "⛔ Этот скрипт должен запускаться от root (или через sudo)." 8 50
        exit 1
    fi
}

ensure_dialog() {
    if ! command -v dialog &> /dev/null; then
        log "📦 Установка dialog..."
        apt update && apt install -y dialog
    fi
}

# -----------------------------------------------------------------------------
# 🛡️ Функции безопасности и фильтрации
# -----------------------------------------------------------------------------
is_desktop_installed() {
    local de_name="$1"
    local config_file="$CONFIG_DIR/$de_name.conf"
    [[ ! -f "$config_file" ]] && return 1
    source "$config_file" 2>/dev/null
    for pkg in $INSTALL_PACKAGES; do
        if dpkg -l "$pkg" &> /dev/null; then
            return 0
        fi
    done
    return 1
}

get_safe_remove_patterns() {
    local de_name="$1"
    local config_file="$CONFIG_DIR/$de_name.conf"
    [[ ! -f "$config_file" ]] && return 1
    source "$config_file" 2>/dev/null

    local other_desktops=()
    for conf in "$CONFIG_DIR"/*.conf; do
        [[ ! -f "$conf" ]] && continue
        local other_name=$(basename "$conf" .conf)
        [[ "$other_name" == "$de_name" ]] && continue
        if is_desktop_installed "$other_name"; then
            other_desktops+=("$other_name")
        fi
    done

    local protected_packages=()
    for other in "${other_desktops[@]}"; do
        local other_conf="$CONFIG_DIR/$other.conf"
        source "$other_conf" 2>/dev/null
        for pkg in $INSTALL_PACKAGES; do
            if dpkg -l "$pkg" &> /dev/null; then
                protected_packages+=("$pkg")
            fi
        done
    done

    local system_protected=(
        "lightdm" "gdm3" "sddm" "lxdm"
        "xserver-xorg" "xinit" "xauth" "x11-xserver-utils"
        "dbus" "policykit-1" "consolekit" "elogind" "systemd" "systemd-sysv"
        "network-manager" "pulseaudio" "alsa-utils" "udisks2" "upower"
    )
    protected_packages+=("${system_protected[@]}")

    local safe_to_remove=()
    for pattern in $REMOVE_PATTERNS; do
        local is_protected=false
        for protected in "${protected_packages[@]}"; do
            if [[ "$pattern" == "$protected" ]] || [[ "$pattern" == *"$protected"* ]] || [[ "$protected" == *"$pattern"* ]]; then
                is_protected=true
                break
            fi
        done
        if [[ "$is_protected" == false ]]; then
            safe_to_remove+=("$pattern")
        else
            log "🛡️  ЗАЩИЩЕНО от удаления: $pattern (нужно для других DE или системы)"
        fi
    done

    echo "${safe_to_remove[*]}"
}

list_desktops() {
    local -n arr_ref=$1
    arr_ref=()
    for conf in "$CONFIG_DIR"/*.conf; do
        [[ ! -f "$conf" ]] && continue
        local de_name=$(basename "$conf" .conf)
        if is_desktop_installed "$de_name"; then
            unset NAME DISPLAY_NAME DESCRIPTION
            source "$conf" 2>/dev/null
            if [[ -n "$NAME" && -n "$DISPLAY_NAME" ]]; then
                arr_ref+=("$NAME" "$DISPLAY_NAME${DESCRIPTION:+ - }$DESCRIPTION")
            fi
        fi
    done
}

# -----------------------------------------------------------------------------
# 🖥️ Управление Окружениями Рабочего Стола (DE)
# -----------------------------------------------------------------------------
detect_current_desktop() {
    if [[ -n "$XDG_CURRENT_DESKTOP" ]]; then
        case "${XDG_CURRENT_DESKTOP,,}" in
            *gnome*) echo "GNOME"; return 0;;
            *kde*|plasma) echo "KDE"; return 0;;
            *xfce*) echo "XFCE"; return 0;;
            *cinnamon*) echo "Cinnamon"; return 0;;
            *mate*) echo "MATE"; return 0;;
            *budgie*) echo "Budgie"; return 0;;
            *i3*) echo "i3"; return 0;;
            *lxqt*) echo "LXQt"; return 0;;
        esac
    fi
    if pgrep -f "gnome-session" &> /dev/null; then echo "GNOME"; return 0; fi
    if pgrep -f "plasmashell" &> /dev/null; then echo "KDE"; return 0; fi
    if pgrep -f "xfce4-session" &> /dev/null; then echo "XFCE"; return 0; fi
    if pgrep -f "cinnamon-session" &> /dev/null; then echo "Cinnamon"; return 0; fi
    if pgrep -f "mate-session" &> /dev/null; then echo "MATE"; return 0; fi
    if pgrep -f "budgie-desktop" &> /dev/null; then echo "Budgie"; return 0; fi
    if pgrep -f "i3" &> /dev/null; then echo "i3"; return 0; fi
    if pgrep -f "lxqt-session" &> /dev/null; then echo "LXQt"; return 0; fi
    if dpkg -l | grep -q "gnome-shell"; then echo "GNOME"; return 0; fi
    if dpkg -l | grep -q "plasma-desktop"; then echo "KDE"; return 0; fi
    if dpkg -l | grep -q "xfce4-session"; then echo "XFCE"; return 0; fi
    if dpkg -l | grep -q "cinnamon"; then echo "Cinnamon"; return 0; fi
    if dpkg -l | grep -q "mate-desktop"; then echo "MATE"; return 0; fi
    if dpkg -l | grep -q "budgie-desktop"; then echo "Budgie"; return 0; fi
    if dpkg -l | grep -q "i3-wm"; then echo "i3"; return 0; fi
    if dpkg -l | grep -q "lxqt"; then echo "LXQt"; return 0; fi
    echo "Unknown"
}

backup_user_configs() {
    local de_name="$1"
    local config_file="$CONFIG_DIR/$de_name.conf"
    [[ ! -f "$config_file" ]] && return 1
    source "$config_file" 2>/dev/null
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/${de_name}_config_backup_$timestamp.tar.gz"
    log "📦 Создание бэкапа конфигов $de_name → $backup_file"
    tar -czf "$backup_file" -C "$HOME" $USER_CONFIG_DIRS 2>/dev/null
    if [[ $? -eq 0 ]]; then
        dialog --msgbox "✅ Бэкап конфигов $de_name сохранён:
$backup_file" 10 60
    else
        dialog --msgbox "⚠️ Некоторые конфиги не найдены — бэкап частичный." 8 50
    fi
}

restore_user_configs() {
    local de_name="$1"
    local config_file="$CONFIG_DIR/$de_name.conf"
    [[ ! -f "$config_file" ]] && { dialog --msgbox "❌ Конфиг не найден: $de_name" 8 40; return 1; }
    source "$config_file" 2>/dev/null
    mapfile -t backups < <(find "$BACKUP_DIR" -name "${de_name}_config_backup_*.tar.gz" 2>/dev/null | sort -r)
    [[ ${#backups[@]} -eq 0 ]] && { dialog --msgbox "❌ Нет бэкапов для $de_name" 8 40; return 1; }
    local options=()
    for backup in "${backups[@]}"; do
        local filename=$(basename "$backup")
        options+=("$backup" "$filename")
    done
    local selected_backup=$(dialog --stdout --menu "Выберите бэкап для восстановления:" 15 70 ${#backups[@]} "${options[@]}")
    [[ $? -ne 0 ]] && return 1
    dialog --infobox "🔄 Восстановление конфигов из:
$selected_backup" 6 60
    log "🔄 Восстановление бэкапа: $selected_backup для $de_name"
    tar -xzf "$selected_backup" -C "$HOME" 2>/dev/null
    dialog --msgbox "✅ Конфиги $de_name восстановлены из бэкапа!" 8 50
    log "✅ Восстановление $de_name завершено"
}

install_desktop() {
    local de_name="$1"
    local config_file="$CONFIG_DIR/$de_name.conf"
    [[ ! -f "$config_file" ]] && { dialog --msgbox "❌ Конфиг не найден: $de_name" 8 40; return 1; }
    source "$config_file" 2>/dev/null
    dialog --infobox "⏳ Установка $DISPLAY_NAME...
Это может занять несколько минут." 6 50
    log "⬇️ Установка DE: $de_name"
    apt update
    if ! apt install -y $INSTALL_PACKAGES; then
        dialog --msgbox "❌ Ошибка при установке $DISPLAY_NAME. Проверьте логи." 8 50
        log "❌ Установка $de_name завершилась с ошибкой"
        return 1
    fi
    if [[ -n "$LOGIN_MANAGER" ]]; then
        systemctl enable "$LOGIN_MANAGER" --force 2>/dev/null
        systemctl restart "$LOGIN_MANAGER" 2>/dev/null || true
        dpkg-reconfigure "$LOGIN_MANAGER" 2>/dev/null || true
    fi
    dialog --msgbox "✅ $DISPLAY_NAME успешно установлен!" 8 40
    log "✅ Установка $de_name завершена"

    # 🔁 Спрашиваем, хочет ли пользователь переключиться
    current_de=$(detect_current_desktop)
    if [[ "$current_de" != "Unknown" ]] && [[ "$current_de" != "$de_name" ]]; then
        dialog --yesno "🔄 Установка завершена.
Хотите ПЕРЕКЛЮЧИТЬСЯ на $DISPLAY_NAME сейчас?
(Будет удалено текущее окружение: $current_de)" 10 60
        if [[ $? -eq 0 ]]; then
            log "🔁 Пользователь выбрал переключение с $current_de на $de_name"
            switch_desktop "$current_de" "$de_name"
        else
            log "ℹ️ Пользователь отказался от переключения. Текущее DE: $current_de, новое: $de_name"
            dialog --msgbox "ℹ️ Вы можете переключиться позже через главное меню → 'Переключить DE'." 8 60
        fi
    else
        if [[ "$current_de" == "$de_name" ]]; then
            dialog --msgbox "ℹ️ $DISPLAY_NAME уже является текущим окружением." 8 50
        else
            dialog --msgbox "ℹ️ Текущее окружение не определено. Переключение недоступно." 8 50
        fi
    fi
}

remove_desktop() {
    local de_name="$1"
    local config_file="$CONFIG_DIR/$de_name.conf"
    [[ ! -f "$config_file" ]] && { dialog --msgbox "❌ Конфиг не найден: $de_name" 8 40; return 1; }
    source "$config_file" 2>/dev/null

    # Показываем, какие другие DE установлены (для контекста)
    local other_installed=()
    for conf in "$CONFIG_DIR"/*.conf; do
        local other_name=$(basename "$conf" .conf)
        [[ "$other_name" == "$de_name" ]] && continue
        if is_desktop_installed "$other_name"; then
            other_installed+=("$other_name")
        fi
    done

    if [[ ${#other_installed[@]} -gt 0 ]]; then
        local others_text=$(IFS=, ; echo "${other_installed[*]}")
        dialog --msgbox "⚠️ В системе также установлены: $others_text
Скрипт автоматически защитит их зависимости." 8 60
    fi

    dialog --yesno "⚠️ Вы уверены, что хотите ПОЛНОСТЬЮ удалить $DISPLAY_NAME?
Будут удалены:
- Все пакеты (кроме защищённых другими DE)
- Зависимости
- Конфиги пользователя
Рекомендуется сделать бэкап!" 14 60
    [[ $? -ne 0 ]] && return 1

    dialog --yesno "Сделать бэкап конфигов перед удалением?" 6 50
    [[ $? -eq 0 ]] && backup_user_configs "$de_name"

    dialog --infobox "🗑️ Удаление $DISPLAY_NAME...
Безопасная очистка (защищены зависимости других DE)." 7 60
    log "🗑️ Удаление DE: $de_name"

    # Получаем безопасный список пакетов для удаления
    local safe_patterns
    safe_patterns=$(get_safe_remove_patterns "$de_name")

    if [[ -z "$safe_patterns" ]]; then
        dialog --msgbox "🛡️ Нечего удалять — все пакеты защищены другими DE или системой." 8 60
        log "🛡️ Безопасное удаление: для $de_name не найдено пакетов для удаления."
    else
        log "🗑️ Безопасное удаление: $safe_patterns"
        apt remove --purge -y $safe_patterns 2>/dev/null
        apt autoremove --purge -y
    fi

    # Удаляем пользовательские конфиги
    for dir in $USER_CONFIG_DIRS; do
        rm -rf "$HOME/$dir"
    done

    # Удаляем осиротевшие пакеты (если есть)
    if command -v deborphan &> /dev/null; then
        apt install -y deborphan 2>/dev/null
        orphaned=$(deborphan)
        if [[ -n "$orphaned" ]]; then
            apt remove --purge -y $orphaned 2>/dev/null
        fi
    fi

    dialog --msgbox "✅ $DISPLAY_NAME полностью удалён (с защитой зависимостей)!" 8 50
    log "✅ Удаление $de_name завершено"
}

switch_desktop() {
    local current_de="$1"
    local target_de="$2"
    dialog --yesno "🔁 Вы собираетесь переключиться с $current_de на $target_de.
Сначала будет удалено текущее окружение.
Продолжить?" 8 60
    [[ $? -ne 0 ]] && return 1
    remove_desktop "$current_de" || { dialog --msgbox "❌ Не удалось удалить $current_de" 8 40; return 1; }
    install_desktop "$target_de"
}

# -----------------------------------------------------------------------------
# 🎨 Управление Темами, Иконками, Курсорами
# -----------------------------------------------------------------------------
list_themes() {
    local -n arr_ref=$1
    arr_ref=()
    for conf in "$THEME_CONFIG_DIR"/*.conf; do
        [[ ! -f "$conf" ]] && continue
        unset NAME DISPLAY_NAME DESCRIPTION
        source "$conf" 2>/dev/null
        if [[ -n "$NAME" && -n "$DISPLAY_NAME" ]]; then
            arr_ref+=("$NAME" "$DISPLAY_NAME${DESCRIPTION:+ - }$DESCRIPTION")
        fi
    done
}

detect_current_themes() {
    local gtk_theme=$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'")
    local icon_theme=$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'")
    local cursor_theme=$(gsettings get org.gnome.desktop.interface cursor-theme 2>/dev/null | tr -d "'")
    if [[ -z "$gtk_theme" ]] && command -v xfconf-query &> /dev/null; then
        gtk_theme=$(xfconf-query -c xsettings -p /Net/ThemeName 2>/dev/null)
        icon_theme=$(xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null)
        cursor_theme=$(xfconf-query -c xsettings -p /Gtk/CursorThemeName 2>/dev/null)
    fi
    if [[ -z "$gtk_theme" ]] && [[ -f "$HOME/.config/kdeglobals" ]]; then
        gtk_theme=$(grep "Theme=" "$HOME/.config/kdeglobals" | cut -d= -f2)
    fi
    echo "GTK: ${gtk_theme:-Не определено} | Icons: ${icon_theme:-Не определено} | Cursor: ${cursor_theme:-Не определено}"
}

backup_themes() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$THEME_BACKUP_DIR/backup_$timestamp"
    mkdir -p "$backup_dir"
    log "📦 Бэкап тем → $backup_dir"
    [[ -d "$HOME/.themes" ]] && cp -r "$HOME/.themes" "$backup_dir/"
    [[ -d "$HOME/.icons" ]] && cp -r "$HOME/.icons" "$backup_dir/"
    [[ -d "$HOME/.local/share/themes" ]] && cp -r "$HOME/.local/share/themes" "$backup_dir/"
    [[ -d "$HOME/.local/share/icons" ]] && cp -r "$HOME/.local/share/icons" "$backup_dir/"
    cp -f "$HOME/.gtkrc-2.0" "$backup_dir/" 2>/dev/null
    mkdir -p "$backup_dir/gtk-3.0" "$backup_dir/gtk-4.0" 2>/dev/null
    cp -f "$HOME/.config/gtk-3.0/settings.ini" "$backup_dir/gtk-3.0/" 2>/dev/null
    cp -f "$HOME/.config/gtk-4.0/settings.ini" "$backup_dir/gtk-4.0/" 2>/dev/null
    dialog --msgbox "✅ Бэкап тем сохранён в:
$backup_dir" 10 60
}

restore_themes() {
    [[ ! -d "$THEME_BACKUP_DIR" ]] && { dialog --msgbox "❌ Нет бэкапов тем." 8 40; return 1; }
    mapfile -t backups < <(find "$THEME_BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | sort -r)
    [[ ${#backups[@]} -eq 0 ]] && { dialog --msgbox "❌ Нет доступных бэкапов." 8 40; return 1; }
    local options=()
    for backup in "${backups[@]}"; do
        local dirname=$(basename "$backup")
        options+=("$backup" "$dirname")
    done
    local selected=$(dialog --stdout --menu "Выберите бэкап для восстановления:" 15 60 ${#backups[@]} "${options[@]}")
    [[ $? -ne 0 ]] && return 1
    dialog --infobox "🔄 Восстановление тем из $selected..." 6 50
    log "🔄 Восстановление тем из $selected"
    [[ -d "$selected/.themes" ]] && cp -r "$selected/.themes" "$HOME/"
    [[ -d "$selected/.icons" ]] && cp -r "$selected/.icons" "$HOME/"
    [[ -d "$selected/themes" ]] && mkdir -p "$HOME/.local/share/themes" && cp -r "$selected/themes" "$HOME/.local/share/"
    [[ -d "$selected/icons" ]] && mkdir -p "$HOME/.local/share/icons" && cp -r "$selected/icons" "$HOME/.local/share/"
    [[ -f "$selected/.gtkrc-2.0" ]] && cp "$selected/.gtkrc-2.0" "$HOME/"
    [[ -f "$selected/gtk-3.0/settings.ini" ]] && {
        mkdir -p "$HOME/.config/gtk-3.0"
        cp "$selected/gtk-3.0/settings.ini" "$HOME/.config/gtk-3.0/"
    }
    [[ -f "$selected/gtk-4.0/settings.ini" ]] && {
        mkdir -p "$HOME/.config/gtk-4.0"
        cp "$selected/gtk-4.0/settings.ini" "$HOME/.config/gtk-4.0/"
    }
    dialog --msgbox "✅ Темы восстановлены!" 8 40
    log "✅ Восстановление тем завершено"
}

install_theme() {
    local theme_name="$1"
    local config_file="$THEME_CONFIG_DIR/${theme_name}.conf"
    [[ ! -f "$config_file" ]] && { dialog --msgbox "❌ Конфиг темы не найден." 8 40; return 1; }
    source "$config_file" 2>/dev/null
    dialog --infobox "📥 Установка $DISPLAY_NAME..." 6 50
    log "📥 Установка темы: $theme_name"
    case "$SOURCE" in
        apt)
            apt update
            eval "$INSTALL_CMD"
            ;;
        archive)
            mkdir -p "$SCRIPT_DIR/themes/cache"
            local archive_path="$SCRIPT_DIR/themes/cache/${theme_name}.tar.xz"
            if [[ ! -f "$archive_path" ]]; then
                curl -L --progress-bar "$URL" -o "$archive_path"
            fi
            mkdir -p "$TARGET_DIR"
            cd "$TARGET_DIR" && eval "$EXTRACT_CMD $archive_path"
            ;;
        *)
            dialog --msgbox "⚠️ Неизвестный источник: $SOURCE" 8 40
            return 1
            ;;
    esac
    dialog --msgbox "✅ $DISPLAY_NAME установлен!" 8 40
    log "✅ Тема $theme_name установлена"
}

# -----------------------------------------------------------------------------
# 🎯 Главное меню
# -----------------------------------------------------------------------------
ensure_root
ensure_dialog

while true; do
    choice=$(dialog --stdout --menu "🖥️ DE Manager v1.3
Управление окружениями и внешним видом" 10 40 4 \
        1 "Установить DE" \
        2 "Удалить DE" \
        3 "Сделать бэкап конфигов DE" \
        4 "Переключить DE (автоопределяет текущее)" \
        5 "Восстановить бэкап конфигов DE" \
        6 "🎨 Управление темами/иконками/курсорами" \
        7 "Просмотреть лог" \
        8 "Выход" )

    case $choice in
        1)
            declare -a desktop_options
            list_desktops desktop_options
            if (( ${#desktop_options[@]} == 0 )); then
                dialog --msgbox "❌ Нет доступных окружений. Проверьте папку configs/." 8 50
                continue
            fi
            if (( ${#desktop_options[@]} % 2 != 0 )); then
                dialog --msgbox "❌ Ошибка: нечётное количество элементов в меню!" 8 50
                log "❌ BUG: Нечётное количество элементов: ${#desktop_options[@]}"
                continue
            fi
            de_choice=$(dialog --stdout --menu "Выберите DE для установки:" 15 60 8 "${desktop_options[@]}")
            [[ $? -eq 0 ]] && install_desktop "$de_choice"
            ;;
        2)
            declare -a desktop_options
            list_desktops desktop_options
            if (( ${#desktop_options[@]} == 0 )); then
                dialog --msgbox "❌ Нет установленных окружений для удаления." 8 50
                continue
            fi
            if (( ${#desktop_options[@]} % 2 != 0 )); then
                dialog --msgbox "❌ Ошибка: нечётное количество элементов в меню!" 8 50
                log "❌ BUG: Нечётное количество элементов: ${#desktop_options[@]}"
                continue
            fi
            de_choice=$(dialog --stdout --menu "Выберите DE для УДАЛЕНИЯ:" 15 60 8 "${desktop_options[@]}")
            [[ $? -eq 0 ]] && remove_desktop "$de_choice"
            ;;
        3)
            declare -a desktop_options
            list_desktops desktop_options
            if (( ${#desktop_options[@]} == 0 )); then
                dialog --msgbox "❌ Нет установленных окружений для бэкапа." 8 50
                continue
            fi
            if (( ${#desktop_options[@]} % 2 != 0 )); then
                dialog --msgbox "❌ Ошибка: нечётное количество элементов в меню!" 8 50
                log "❌ BUG: Нечётное количество элементов: ${#desktop_options[@]}"
                continue
            fi
            de_choice=$(dialog --stdout --menu "Выберите DE для бэкапа конфигов:" 15 60 8 "${desktop_options[@]}")
            [[ $? -eq 0 ]] && backup_user_configs "$de_choice"
            ;;
        4)
            current_detected=$(detect_current_desktop)
            if [[ "$current_detected" == "Unknown" ]]; then
                dialog --msgbox "Не удалось определить текущее окружение. Выберите вручную." 8 50
                declare -a desktop_options
                list_desktops desktop_options
                if (( ${#desktop_options[@]} == 0 )); then
                    dialog --msgbox "❌ Нет установленных окружений." 8 50
                    continue
                fi
                if (( ${#desktop_options[@]} % 2 != 0 )); then
                    dialog --msgbox "❌ Ошибка: нечётное количество элементов в меню!" 8 50
                    log "❌ BUG: Нечётное количество элементов: ${#desktop_options[@]}"
                    continue
                fi
                current=$(dialog --stdout --menu "Какое окружение ВЫ УДАЛЯЕТЕ?" 12 60 8 "${desktop_options[@]}")
            else
                dialog --msgbox "Автоопределено: вы используете $current_detected" 7 50
                current="$current_detected"
            fi
            [[ $? -ne 0 ]] && continue
            declare -a desktop_options
            list_desktops desktop_options
            if (( ${#desktop_options[@]} == 0 )); then
                dialog --msgbox "❌ Нет доступных окружений для установки." 8 50
                continue
            fi
            if (( ${#desktop_options[@]} % 2 != 0 )); then
                dialog --msgbox "❌ Ошибка: нечётное количество элементов в меню!" 8 50
                log "❌ BUG: Нечётное количество элементов: ${#desktop_options[@]}"
                continue
            fi
            target=$(dialog --stdout --menu "Какое окружение УСТАНАВЛИВАЕТЕ?" 12 60 8 "${desktop_options[@]}")
            [[ $? -eq 0 ]] && switch_desktop "$current" "$target"
            ;;
        5)
            declare -a desktop_options
            list_desktops desktop_options
            if (( ${#desktop_options[@]} == 0 )); then
                dialog --msgbox "❌ Нет установленных окружений для восстановления." 8 50
                continue
            fi
            if (( ${#desktop_options[@]} % 2 != 0 )); then
                dialog --msgbox "❌ Ошибка: нечётное количество элементов в меню!" 8 50
                log "❌ BUG: Нечётное количество элементов: ${#desktop_options[@]}"
                continue
            fi
            de_choice=$(dialog --stdout --menu "Выберите DE для восстановления конфигов:" 15 60 8 "${desktop_options[@]}")
            [[ $? -eq 0 ]] && restore_user_configs "$de_choice"
            ;;
        6)
            while true; do
                theme_choice=$(dialog --stdout --menu "🎨 Управление темами/иконками/курсорами" 12 60 5 \
                    1 "Установить тему/иконки/курсор" \
                    2 "Показать текущие темы" \
                    3 "Сделать бэкап тем" \
                    4 "Восстановить бэкап тем" \
                    5 "Назад" )

                case $theme_choice in
                    1)
                        declare -a theme_options
                        list_themes theme_options
                        if (( ${#theme_options[@]} == 0 )); then
                            dialog --msgbox "❌ Нет доступных тем. Проверьте папку themes/configs/." 8 50
                            continue
                        fi
                        if (( ${#theme_options[@]} % 2 != 0 )); then
                            dialog --msgbox "❌ Ошибка: нечётное количество элементов в меню!" 8 50
                            log "❌ BUG: Нечётное количество элементов: ${#theme_options[@]}"
                            continue
                        fi
                        selected=$(dialog --stdout --menu "Выберите элемент для установки:" 15 60 8 "${theme_options[@]}")
                        [[ $? -eq 0 ]] && install_theme "$selected"
                        ;;
                    2)
                        current=$(detect_current_themes)
                        dialog --msgbox "Текущие темы:
$current" 10 60
                        ;;
                    3)
                        backup_themes
                        ;;
                    4)
                        restore_themes
                        ;;
                    5|*)
                        break
                        ;;
                esac
            done
            ;;
        7)
            dialog --textbox "$LOG_FILE" 20 80
            ;;
        8|*)
            dialog --msgbox "👋 Спасибо за использование DE Manager!" 7 40
            exit 0
            ;;
    esac
done