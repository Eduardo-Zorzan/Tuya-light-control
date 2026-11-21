# Spec Delta

## Purpose

Provides a reliable local-network link between the app and each registered Tuya light, so commands reach the light quickly and connection problems are detected, recovered from and reported without user intervention.

## ADDED Requirements

### Requirement: Local protocol communication
The system SHALL communicate with each light directly over the local network using the Tuya local protocol, supporting protocol versions 3.3, 3.4 and 3.5, encrypted with the light's local key. Everyday control SHALL NOT require internet access or Tuya cloud services.

#### Scenario: Control without internet
- **GIVEN** a registered light on the same LAN and the Mac has no internet access
- **WHEN** the user changes the light's color
- **THEN** the light changes color

#### Scenario: Protocol version 3.4 or 3.5 light
- **GIVEN** a registered light that speaks protocol 3.4 or 3.5
- **WHEN** the system connects to it
- **THEN** the system completes the session key negotiation and can read and set the light's state

### Requirement: Protocol version auto-detection
When a light's protocol version is not configured, the system SHALL determine it automatically (from discovery broadcasts or by trying supported versions) and remember the version that worked.

#### Scenario: Unknown version resolved
- **GIVEN** a light registered without a protocol version
- **WHEN** the system connects successfully using version 3.4
- **THEN** the light is stored as version 3.4 and later connections use 3.4 first

### Requirement: Persistent connection with heartbeat
The system SHALL keep one persistent connection per light while the app runs and SHALL send a heartbeat at least every 10 seconds. A connection SHALL be considered dead when no response is received within 5 seconds of a heartbeat or command, or when the socket reports an error.

#### Scenario: Light unplugged
- **GIVEN** a connected light
- **WHEN** the light loses power
- **THEN** within 15 seconds the light's status changes to "Offline/Reconnecting"

### Requirement: Automatic reconnection with backoff
After a connection is lost or fails, the system SHALL retry automatically using exponential backoff with jitter, starting at about 1 second and capped at 30 seconds, until the light is removed or the app quits. A successful reconnection SHALL reset the backoff.

#### Scenario: Light comes back
- **GIVEN** a light that has been offline for several minutes
- **WHEN** the light is powered on again
- **THEN** the system reconnects within at most 30 seconds plus the light's boot time, without user action, and its status returns to "Connected"

#### Scenario: Backoff cap
- **GIVEN** a light that stays unreachable
- **WHEN** reconnection attempts keep failing
- **THEN** the interval between attempts never exceeds 30 seconds

### Requirement: Recovery after sleep and network changes
The system SHALL drop stale connections and reconnect immediately (bypassing the current backoff delay) when the Mac wakes from sleep, when the active network changes, and when the user opens the popover while a light is not connected.

#### Scenario: Wake from sleep
- **GIVEN** the Mac slept for an hour with a light connected
- **WHEN** the Mac wakes
- **THEN** the system reconnects to the light without waiting for heartbeat timeouts or backoff delays

#### Scenario: Popover opened while offline
- **GIVEN** a light in backoff waiting 30 seconds for its next attempt
- **WHEN** the user opens the popover
- **THEN** the system attempts to reconnect immediately

### Requirement: IP address rediscovery
The system SHALL listen for Tuya local discovery broadcasts and SHALL update a light's stored IP address when the light is seen at a new address, so that DHCP address changes do not require reconfiguration.

#### Scenario: Light changes IP
- **GIVEN** a light stored at 192.168.0.20 that now has address 192.168.0.31
- **WHEN** the system receives the light's discovery broadcast from 192.168.0.31
- **THEN** the stored address is updated and the system connects to 192.168.0.31

### Requirement: Command coalescing
For each light, the system SHALL send only the most recent pending value of each setting, discarding superseded values that have not been sent yet, and SHALL limit the send rate so that continuous slider or color wheel movement does not build a backlog.

#### Scenario: Fast slider drag
- **GIVEN** a connected light
- **WHEN** the user drags the brightness slider through 50 values in one second and releases it
- **THEN** the light ends at the final value and no stale intermediate values are applied after the release

### Requirement: Command delivery confirmation and retry
The system SHALL treat a command as delivered only after the light acknowledges it or reports the new state. A command that is not confirmed within the response timeout SHALL be retried once on a fresh connection; if it still fails, the UI SHALL show that the change was not applied.

#### Scenario: Command lost on a dead socket
- **GIVEN** a connection that died silently
- **WHEN** the user turns the light off
- **THEN** the system detects the timeout, reconnects, resends the latest state, and the light turns off

#### Scenario: Command cannot be delivered
- **GIVEN** a light that is unreachable
- **WHEN** the user changes its color
- **THEN** the UI indicates the light is offline and that the change was not applied

### Requirement: Commands while offline
While a light is not connected, the system SHALL keep only the latest desired state for that light and SHALL apply it once the connection is re-established, provided the desired state is less than 60 seconds old; older pending changes SHALL be discarded.

#### Scenario: Brief disconnect during a change
- **GIVEN** a light that is reconnecting
- **WHEN** the user picks a new color and the light reconnects 5 seconds later
- **THEN** the light shows the newly picked color

### Requirement: Connection status reporting
The system SHALL expose a per-light connection status of one of: Connected, Connecting, Offline (with time of next retry), or Error with a cause (wrong local key, unsupported protocol, connection refused). The status SHALL update in the UI within 1 second of changing.

#### Scenario: Wrong local key
- **GIVEN** a light registered with an incorrect local key
- **WHEN** the system connects and the light's response cannot be decrypted or the session negotiation fails
- **THEN** the light's status shows "Error: invalid local key" and the system does not retry faster than the backoff schedule

#### Scenario: Connection slot taken
- **GIVEN** a light that refuses or resets the connection because another client holds its local connection
- **WHEN** the system attempts to connect
- **THEN** the status shows "Error: connection refused (another app may be connected)" and the system keeps retrying with backoff

### Requirement: Independent connections per light
Connection problems with one light SHALL NOT delay or block commands to other lights.

#### Scenario: One light offline during "all lights" control
- **GIVEN** three registered lights with one offline
- **WHEN** the user changes the color for all lights
- **THEN** the two connected lights change color immediately and the offline light is reported as not updated
