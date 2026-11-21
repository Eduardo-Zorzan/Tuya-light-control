# Spec Delta

## Purpose

Lets the user register, edit and remove their Tuya lights, keeps each light's credentials secure, and chooses which light (or all lights) the controls act on.

## ADDED Requirements

### Requirement: Import lights from Tuya IoT Cloud
The system SHALL let the user import lights by entering a Tuya IoT Platform Access ID, Access Secret and data-center region. The system SHALL fetch the account's lights with their device ID, name, local key and product information, and let the user choose which lights to add. Cloud access SHALL be used only for this import or an explicit refresh.

#### Scenario: Successful import
- **GIVEN** valid Tuya IoT credentials linked to the user's app account
- **WHEN** the user runs the import
- **THEN** the system lists the account's lights and adds the selected ones with their local keys

#### Scenario: Invalid cloud credentials
- **WHEN** the user runs the import with an invalid Access Secret
- **THEN** the system shows the error returned by Tuya and adds no lights

### Requirement: Manual light registration
The system SHALL let the user add a light manually by entering a name, device ID and local key, with optional IP address and protocol version. A light without an IP address SHALL be located through local discovery.

#### Scenario: Manual add without IP
- **WHEN** the user adds a light with name, device ID and local key only
- **THEN** the light is saved and the system connects to it once it is found by discovery

#### Scenario: Missing required field
- **WHEN** the user tries to save a light without a local key
- **THEN** the system rejects the entry and highlights the missing field

### Requirement: Refresh local keys
The system SHALL let the user re-fetch local keys from Tuya IoT Cloud for already registered lights, since a light's local key changes when it is re-paired.

#### Scenario: Light re-paired
- **GIVEN** a light showing "Error: invalid local key" after being re-paired in the phone app
- **WHEN** the user runs "refresh keys"
- **THEN** the light's local key is updated and the system reconnects

### Requirement: Secure credential storage
Local keys and the Tuya IoT Access Secret SHALL be stored in the macOS Keychain and SHALL NOT be written in plain text to configuration files or logs.

#### Scenario: Config file inspection
- **GIVEN** a registered light
- **WHEN** the app's configuration files and logs are inspected
- **THEN** they contain no local key or Access Secret

### Requirement: Edit and remove lights
The system SHALL let the user rename a light, edit its IP address, protocol version and local key, and remove it. Removing a light SHALL close its connection and delete its Keychain entry.

#### Scenario: Remove a light
- **WHEN** the user removes a light
- **THEN** it disappears from the light selector, its connection is closed, and its local key is deleted from the Keychain

### Requirement: Active light selection
The system SHALL let the user select one registered light as the active light, or select "All lights", and the light controls SHALL act on the selection. The selection SHALL persist across app restarts and SHALL be shown in the popover header.

#### Scenario: Switch active light
- **GIVEN** two registered lights "Fita LED Mesa" and "Lâmpada Estúdio"
- **WHEN** the user selects "Lâmpada Estúdio"
- **THEN** the header shows "Lâmpada Estúdio" with its connection status and the controls show and change that light's state

#### Scenario: Selection persists
- **GIVEN** the user selected "All lights"
- **WHEN** the app is restarted
- **THEN** "All lights" is still selected

### Requirement: Light capability mapping
The system SHALL determine for each light which data points it uses for power, mode, brightness, color temperature and color (Tuya standard v2 data points 20–24 or legacy data points 1–5), and the supported color temperature range, defaulting to 2700K–6500K when unknown and allowing the user to override it.

#### Scenario: Legacy light
- **GIVEN** a light that reports data points 1–5 instead of 20–24
- **WHEN** the system connects to it
- **THEN** controls work using the legacy data points and value scales

### Requirement: First-run setup
When no lights are registered, the popover SHALL show a setup view offering cloud import or manual entry instead of the light controls.

#### Scenario: First launch
- **GIVEN** a fresh installation
- **WHEN** the user opens the popover
- **THEN** the setup view is shown with "Import from Tuya IoT" and "Add manually" options
