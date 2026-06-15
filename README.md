<div align="center">

# FlowCutter

GUI-утилита для [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) с автоматическим подбором стратегии

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://docs.microsoft.com/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-lightgrey.svg)](https://www.microsoft.com/windows)

</div>

> **FlowCutter** — GUI-обёртка над [zapret](https://github.com/bol-van/zapret) с функцией автоподбора оптимальной стратегии обхода DPI для Discord и YouTube.

## Возможности

- **Автоподбор стратегии** — проверяет все `general*.bat` стратегии, пингует Discord и YouTube, выставляет рейтинг
- **Управление доменами** — добавление/удаление доменов в списки bypass и exclude прямо из GUI
- **Настройка zapret** — Game Filter, IPSet Filter, автопроверка обновлений, управление службой
- **Скрытый запуск** — стратегии запускаются без всплывающих окон

## Быстрый старт

1. Включите **Secure DNS** в браузере или Windows 11
2. Скачайте и распакуйте [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube/releases/latest) в путь без кириллицы
3. Скопируйте `strategy_finder.ps1` и `strategy finder.bat` в корень распакованной папки
4. Запустите **`strategy finder.bat`** от имени администратора
5. Нажмите **Find Best** и дождитесь результатов
6. Выберите лучшую стратегию и нажмите **Launch**

## Структура GUI

### Strategy Finder
Автоматически тестирует все стратегии и показывает результаты в таблице:
- **Discord** — доступность discord.com и gateway.discord.gg
- **YouTube** — доступность youtube.com и youtu.be
- **Score** — общий процент успеха

### Domains
Управление пользовательскими списками доменов:
- **Bypass** — домены, для которых zapret работает (файл `list-general-user.txt`)
- **Exclude** — домены, для которых zapret НЕ работает (файл `list-exclude-user.txt`)

### Settings
- **Game Filter** — переключение режима обхода для игр (Disabled / TCP+UDP / TCP / UDP)
- **IPSet Filter** — управление фильтрацией по IP (None / Loaded / Any)
- **Auto Update** — вкл/выкл автопроверки обновлений
- **Service** — установка/удаление службы zapret
- **Update Lists** — обновление IPSet и hosts из репозитория

## Требования

- Windows 10/11
- PowerShell 3.0+
- Права администратора
- [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube/releases/latest) распакованный в корне

## Как работает автоподбор

1. Скрипт находит все файлы `general*.bat` в корне
2. Для каждой стратегии:
   - Останавливает предыдущий `winws.exe`
   - Запускает новую стратегию (скрыто)
   - Проверяет HTTP/TLS 1.2/TLS 1.3 для Discord и YouTube
   - Записывает результаты
3. Результаты сортируются по Score
4. Лучшая стратегия предлагается для запуска

## Связанные проекты

- [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — оригинальный репозиторий с стратегиями
- [zapret](https://github.com/bol-van/zapret) — оригинальный zapret от bol-van
- [WinDivert](https://github.com/basil00/WinDivert) — драйвер перехвата трафика

## Лицензия

[MIT](LICENSE.txt) — с сохранением лицензий зависимых проектов (WinDivert: LGPLv3/GPLv2)
