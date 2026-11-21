# Spec Delta

## Purpose

Offers ready-made lighting presets that set mode, color or temperature, and brightness in one click from the Cenas tab.

## ADDED Requirements

### Requirement: Built-in scenes
The Cenas tab SHALL list these scenes, each showing its name and a short description:

| Scene | Setting |
|---|---|
| Foco Profundo | White 6200K, 100% |
| Cyberpunk | Color hue 295°, saturation 92%, 90% |
| Pôr do Sol | Color hue 26°, saturation 95%, 70% |
| Leitura Noturna | White 2500K, 45% |
| Modo Cinema | Color hue 228°, saturation 94%, 30% |
| Floresta Calma | Color hue 145°, saturation 82%, 60% |

#### Scenario: Scenes listed
- **WHEN** the user opens the Cenas tab
- **THEN** the six scenes are shown in a two-column grid with their descriptions

### Requirement: Apply scene
Selecting a scene SHALL turn the selected light(s) on and apply the scene's mode, color or temperature and brightness as a single change, and the Luz tab controls SHALL reflect the new state. White-temperature values outside a light's supported range SHALL be clamped.

#### Scenario: Apply color scene
- **WHEN** the user selects "Cyberpunk"
- **THEN** the light shows magenta at 90% brightness and the Luz tab shows color mode with the matching wheel position

#### Scenario: Apply white scene on a limited light
- **GIVEN** a light supporting 2700K–6500K
- **WHEN** the user selects "Leitura Noturna"
- **THEN** the light shows 2700K white at 45%

### Requirement: Active scene indication
The scene matching the light's current state SHALL be highlighted until the user changes the light in any other way.

#### Scenario: Scene highlight cleared
- **GIVEN** "Pôr do Sol" is active and highlighted
- **WHEN** the user moves the brightness slider
- **THEN** no scene is highlighted
