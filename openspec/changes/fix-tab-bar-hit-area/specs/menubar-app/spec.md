# Spec Delta

## Purpose

Defines how the app lives in the macOS menu bar: its icon, the popover window it opens, keyboard access, startup behavior and how it quits.

## ADDED Requirements

### Requirement: Segmented controls respond across their full area
Each segment of the popover's segmented controls (the Luz / Cenas / Ajustes tab bar and the Cor RGB / Branco CCT mode toggle on the Luz tab) SHALL respond to a click anywhere inside its visible bounds, including padding around the icon and label. This SHALL hold whether the segment is active or inactive.

#### Scenario: Click empty space of an inactive tab
- **GIVEN** the popover is open on the Luz tab
- **WHEN** the user clicks inside the Cenas tab segment, away from its icon and "Cenas" label
- **THEN** the Cenas tab becomes active and its content replaces the Luz content

#### Scenario: Click the edge of a tab segment
- **GIVEN** the popover is open on the Cenas tab
- **WHEN** the user clicks near the left or right edge of the Ajustes segment, still within its pill area
- **THEN** the Ajustes tab becomes active

#### Scenario: Click empty space of the inactive mode option
- **GIVEN** the Luz tab shows the light in Cor RGB mode
- **WHEN** the user clicks inside the Branco CCT option's pill, outside its text
- **THEN** the light switches to white mode and Branco CCT is shown as selected

#### Scenario: Clicks outside the segments do nothing
- **WHEN** the user clicks in the gap between two tab segments or outside the tab bar
- **THEN** the selected tab does not change
