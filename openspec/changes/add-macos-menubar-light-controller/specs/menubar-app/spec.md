# Spec Delta

## Purpose

Defines how the app lives in the macOS menu bar: its icon, the popover window it opens, keyboard access, startup behavior and how it quits.

## ADDED Requirements

### Requirement: Menu bar only presence
The app SHALL run as a menu bar utility with a cat-bulb template icon and a status dot in the macOS menu bar, and SHALL NOT show a Dock icon or appear in the app switcher.

#### Scenario: Launch
- **WHEN** the app starts
- **THEN** the cat-bulb icon appears in the menu bar and no Dock icon appears

### Requirement: Popover toggle
Clicking the menu bar icon SHALL open the control popover anchored below the icon, and clicking it again SHALL close it. The popover SHALL open in under 300 ms showing the last known state immediately, without waiting for the light.

#### Scenario: Open popover
- **WHEN** the user clicks the menu bar icon
- **THEN** the popover appears below the icon with the Luz tab and the last known light state

### Requirement: Popover dismissal
The popover SHALL close when the user clicks outside it, switches to another app, or presses Escape.

#### Scenario: Click outside
- **GIVEN** the popover is open
- **WHEN** the user clicks on the desktop
- **THEN** the popover closes

### Requirement: Popover layout and style
The popover SHALL follow the reference mockup: a dark translucent window with rounded corners and an arrow pointing to the icon, a header with the active light name and connection dot, the power switch, the cat-bulb emblem and the title, and a segmented control with the tabs "Luz", "Cenas" and "Ajustes". The UI language SHALL be Brazilian Portuguese.

#### Scenario: Switch tab
- **WHEN** the user clicks "Cenas"
- **THEN** the Cenas tab is highlighted and its content replaces the Luz content

### Requirement: Settings tab
The Ajustes tab SHALL contain the active light selector (including "All lights"), the list of registered lights with their connection status and a way to add, edit or remove lights, the "Iniciar com o macOS" toggle, the app version, the shortcut hint, and a "Sair" (Quit) action.

#### Scenario: Light status in settings
- **GIVEN** one light connected and one offline
- **WHEN** the user opens Ajustes
- **THEN** each light is listed with its own status

### Requirement: Global shortcut
Pressing ⌘⇧L anywhere in macOS SHALL toggle the popover.

#### Scenario: Shortcut from another app
- **GIVEN** another app is focused and the popover is closed
- **WHEN** the user presses ⌘⇧L
- **THEN** the popover opens

### Requirement: Launch at login
The "Iniciar com o macOS" setting SHALL register or unregister the app as a login item, and SHALL default to on after first setup.

#### Scenario: Disable launch at login
- **WHEN** the user turns "Iniciar com o macOS" off
- **THEN** the app is removed from the macOS login items and does not start at next login

### Requirement: Quit
The app SHALL provide a Quit action in the Ajustes tab and in the menu bar icon's right-click menu. Quitting SHALL close all light connections without changing the lights' state.

#### Scenario: Quit leaves lights as they are
- **GIVEN** the light is on in blue
- **WHEN** the user quits the app
- **THEN** the app exits and the light stays on in blue

### Requirement: Local network permission
The app SHALL declare its use of the local network so macOS prompts for Local Network access, and SHALL show a clear message with a link to System Settings when access is denied.

#### Scenario: Permission denied
- **GIVEN** the user denied Local Network access
- **WHEN** the app tries to connect to a light
- **THEN** the popover explains that Local Network access is required and how to enable it
