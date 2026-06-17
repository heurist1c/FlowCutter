<div align="center">

# FlowCutter

GUI-утилита для [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) с автоматическим подбором стратегии

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://docs.microsoft.com/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-lightgrey.svg)](https://www.microsoft.com/windows)

</div>

> **FlowCutter** — GUI-обёртка над [zapret](https://github.com/bol-van/zapret) с функцией автоподбора оптимальной стратегии обхода DPI для Discord и YouTube.
> Если понравился проект,пожалуйста,поставьте звездочку. Мне будет очень приятно

## Возможности

- **Автоподбор стратегии** — проверяет все `general*.bat` стратегии, пингует Discord и YouTube, выставляет рейтинг
- **Управление доменами** — добавление/удаление доменов в списки bypass и exclude прямо из GUI
- **Настройка zapret** — Game Filter, IPSet Filter, управление службой
- **Обновления** — двойная проверка: база (Flowseal) + GUI-обёртка (FlowCutter)
- **Скрытый запуск** — стратегии запускаются без всплывающих окон

## Установка

FlowCutter — это **оверлей** поверх [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube). Он не содержит сам `winws.exe` и WinDivert — эти файлы берутся из оригинального репозитория.

### Шаг 1. Скачайте оригинальный zapret

Скачайте последний релиз [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube/releases/latest) (ZIP или RAR) и распакуйте в путь **без кириллицы и пробелов**.

```
C:\zapret\
├── bin\              ← winws.exe, WinDivert, .bin пейлоады (из Flowseal)
├── general.bat
├── general (ALT).bat
├── lists\
├── service.bat
└── ...
```

### Шаг 2. Скачайте FlowCutter

Скачайте [последний релиз FlowCutter](https://github.com/heurist1c/FlowCutter/releases/latest) (Source code zip) и распакуйте.

### Шаг 3. Замените файлы

Скопируйте **всё содержимое** из архива FlowCutter в корень распакованного zapret. Подтвердите замену файлов:

```
C:\zapret\
├── bin\              ← НЕ трогаем (из Flowseal)
├── general.bat       ← заменён на версию FlowCutter
├── lists\            ← заменены списки доменов
├── service.bat       ← заменён на версию FlowCutter
├── strategy_finder.ps1   ← ДОБАВЛЕН (GUI)
├── strategy finder.bat   ← ДОБАВЛЕН (лаунчер)
├── utils\            ← ДОБАВЛЕН (утилиты)
└── .service\         ← ДОБАВЛЕН (версии, данные)
```

### Шаг 4. Запустите

Запустите **`strategy finder.bat`** от имени администратора.

## Использование

### Strategy Finder (Автоподбор)

1. Нажмите **Find Best**
2. Дождитесь результатов — каждая стратегия тестируется на Discord и YouTube
3. Лучшая стратегия подсвечивается в таблице
4. Нажмите **Launch** для запуска выбранной стратегии

### Domains (Управление доменами)

- **Bypass** — домены, для которых zapret работает (`list-general-user.txt`)
- **Exclude** — домены, для которых zapret НЕ работает (`list-exclude-user.txt`)

Введите домен в поле и нажмите `+ Bypass` или `+ Exclude`.

### Settings (Настройки)

- **Game Filter** — режим обхода для игр (Disabled / TCP+UDP / TCP / UDP)
- **IPSet Filter** — фильтрация по IP-адресам (None / Loaded / Any)
- **Updates** — проверка обновлений базы (Flowseal) и GUI-обёртки (FlowCutter)
- **Service** — установка/удаление службы zapret
- **Update IPSet / Hosts** — обновление списков из репозитория Flowseal

## Обновления

FlowCutter проверяет обновления из **двух источников**:

| Источник | Что обновляет |
|----------|---------------|
| [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) | `general*.bat`, `lists/`, `service.bat` |
| [heurist1c/FlowCutter](https://github.com/heurist1c/FlowCutter) | `strategy_finder.ps1`, GUI, `utils/` |

## Требования

- Windows 10/11
- PowerShell 3.0+
- Права администратора (WinDivert требует elevated privileges)

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

- [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — оригинальный репозиторий с стратегиями и бинарниками
- [zapret](https://github.com/bol-van/zapret) — оригинальный zapret от bol-van
- [WinDivert](https://github.com/basil00/WinDivert) — драйвер перехвата трафика

## Лицензия

[MIT](LICENSE.txt) — с сохранением лицензий зависимых проектов (WinDivert: LGPLv3/GPLv2)
