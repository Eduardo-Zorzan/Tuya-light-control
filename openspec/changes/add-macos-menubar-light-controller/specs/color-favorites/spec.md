# Spec Delta

## Purpose

Lets the user keep a short list of favorite colors they can save from the current light color and re-apply with one click.

## ADDED Requirements

### Requirement: Default favorites
On first run the favorites list SHALL contain the eight default colors `#0A84FF`, `#BF5AF2`, `#FF375F`, `#FF9F0A`, `#30D158`, `#64D2FF`, `#FF453A`, `#FFD60A`.

#### Scenario: First run
- **GIVEN** a fresh installation
- **WHEN** the user opens the Luz tab
- **THEN** the eight default favorite colors are shown with the count "8/12"

### Requirement: Save current color
The "+ Salvar" action SHALL add the current light color to the start of the favorites list and briefly confirm with "✓ Salva!". A color already in the list SHALL NOT be added again; the action SHALL instead show "✓ Já salva".

#### Scenario: Save new color
- **GIVEN** the current color `#12AB34` is not a favorite
- **WHEN** the user clicks "+ Salvar"
- **THEN** `#12AB34` appears first in the favorites list and the count increases by one

#### Scenario: Save duplicate
- **GIVEN** `#0A84FF` is already a favorite and is the current color
- **WHEN** the user clicks "+ Salvar"
- **THEN** the list does not change and the button shows "✓ Já salva"

### Requirement: Favorites limit
The favorites list SHALL hold at most 12 colors. Saving a new color when the list is full SHALL remove the last (oldest) color in the list.

#### Scenario: Save when full
- **GIVEN** 12 favorites
- **WHEN** the user saves a new color
- **THEN** the new color is first, the last color is removed, and the count shows "12/12"

### Requirement: Apply favorite
Clicking a favorite SHALL set the selected light(s) to that color in color mode, turning the light on if it is off, and move the color wheel cursor to that color.

#### Scenario: Apply favorite
- **WHEN** the user clicks the `#FF9F0A` favorite
- **THEN** the light shows `#FF9F0A` and the hex readout shows `#FF9F0A`

### Requirement: Delete favorite
Hovering or focusing a favorite SHALL reveal a delete control; using it SHALL remove that color from the list without changing the light.

#### Scenario: Delete favorite
- **WHEN** the user deletes the `#30D158` favorite
- **THEN** `#30D158` is no longer listed and the count decreases by one

#### Scenario: Empty list
- **WHEN** the user deletes every favorite
- **THEN** the list shows "Nenhuma favorita salva"

### Requirement: Favorites persistence
The favorites list SHALL persist across app restarts and SHALL be shared across all lights.

#### Scenario: Restart
- **GIVEN** the user saved `#12AB34`
- **WHEN** the app is quit and reopened
- **THEN** `#12AB34` is still in the favorites list
