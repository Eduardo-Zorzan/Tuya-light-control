# Spec Delta

## Purpose

Controls the power, color, white temperature and brightness of the selected light or lights from the popover, and keeps the controls in sync with what the light is actually doing.

## ADDED Requirements

### Requirement: Power control
The popover SHALL provide a power switch that turns the selected light(s) on and off, labeled "Ligada" or "Desligada" to match the state. Changing color, temperature, brightness, a favorite or a scene while the light is off SHALL turn it on.

#### Scenario: Turn off
- **GIVEN** the active light is on
- **WHEN** the user toggles the power switch
- **THEN** the light turns off and the switch shows "Desligada"

#### Scenario: Color change turns light on
- **GIVEN** the active light is off
- **WHEN** the user picks a color on the color wheel
- **THEN** the light turns on with that color

### Requirement: Color mode selection
The popover SHALL let the user switch between "Cor RGB" (color) mode and "Branco CCT" (white) mode. Switching mode SHALL restore the last color or last white temperature used in that mode.

#### Scenario: Switch to white
- **GIVEN** the light shows blue in color mode and the last white temperature was 4200K
- **WHEN** the user selects "Branco CCT"
- **THEN** the light shows white at 4200K and the white mode button is highlighted

### Requirement: RGB color selection
In color mode, the popover SHALL provide a hue/saturation color wheel; clicking or dragging on it SHALL set the light's hue and saturation. The selected color SHALL be shown as a swatch and hex code (e.g. `#0A84FF`), and the light SHALL follow the drag continuously.

#### Scenario: Drag across the wheel
- **WHEN** the user drags the wheel cursor from red to green
- **THEN** the light transitions through the dragged colors, and the swatch and hex code show the final color

### Requirement: Hex color entry
The user SHALL be able to type a hex color code into the color readout to set the color. Invalid codes SHALL be rejected without changing the light.

#### Scenario: Valid hex
- **WHEN** the user enters `#FF375F`
- **THEN** the light shows that color and the wheel cursor moves to its hue and saturation

#### Scenario: Invalid hex
- **WHEN** the user enters `#ZZ12`
- **THEN** the field shows an error and the light does not change

### Requirement: Brightness control
The popover SHALL provide a brightness slider from 1% to 100% showing the current percentage. In color mode it SHALL set the color's brightness; in white mode it SHALL set the white brightness. The slider fill SHALL take the light's current color.

#### Scenario: Set brightness
- **WHEN** the user drags the brightness slider to 40%
- **THEN** the light dims to 40% and the label shows "40%"

### Requirement: Color temperature control
The popover SHALL provide a color temperature ("Tom de Calor") slider spanning the light's supported Kelvin range, showing the value with a label "Quente", "Neutro" or "Frio". Using the slider SHALL switch the light to white mode.

#### Scenario: Warm white
- **WHEN** the user drags the temperature slider to its warm end on a 2700K–6500K light
- **THEN** the light shows 2700K white and the label reads "2700K • Quente"

### Requirement: Temperature quick presets
The popover SHALL offer quick temperature presets "Vela" (2400K), "Leitura" (4200K) and "Foco" (6200K). A preset outside the light's supported range SHALL be clamped to the nearest supported value.

#### Scenario: Preset below range
- **GIVEN** a light supporting 2700K–6500K
- **WHEN** the user selects "Vela"
- **THEN** the light shows 2700K white

### Requirement: State synchronization from the light
The controls SHALL reflect the light's actual state, read when the connection is established and updated whenever the light reports a change, including changes made from the phone app or a physical switch. A user change in progress (an active drag) SHALL NOT be overwritten by incoming reports.

#### Scenario: Change from phone app
- **GIVEN** the popover is open
- **WHEN** someone sets the light to green from the phone app
- **THEN** within 2 seconds the popover shows green and the matching hex code

### Requirement: Feedback for unapplied changes
When the selected light is not connected, the controls SHALL remain usable but SHALL clearly indicate the light is offline, and SHALL indicate when a change could not be applied.

#### Scenario: Control an offline light
- **GIVEN** the active light is offline
- **WHEN** the popover is opened
- **THEN** the header shows the offline status and the controls show the last known state marked as not current

### Requirement: Controlling all lights
When "All lights" is selected, every change SHALL be sent to each registered light, and the controls SHALL show the most recent state the user set (or, before any change, the state of the first connected light).

#### Scenario: Set color for all
- **GIVEN** "All lights" is selected with three connected lights
- **WHEN** the user picks orange
- **THEN** all three lights show orange

### Requirement: Live color indicators
The menu bar icon status dot, the popover's cat-bulb emblem and its halo SHALL take the current light color while the light is on, and SHALL appear gray when the light is off or offline.

#### Scenario: Light turned off
- **WHEN** the active light is turned off
- **THEN** the menu bar status dot and the emblem turn gray
