import SwiftUI
import TuyaLocal

/// User-facing (pt-BR) text and colors for connection statuses.
enum ConnectionText {
    static func short(_ status: ConnectionStatus, now: Date = Date()) -> String {
        switch status {
        case .idle: return "Aguardando"
        case .connecting: return "Conectando…"
        case .connected: return "Conectada"
        case .offline(let retry): return "Offline • nova tentativa em \(seconds(until: retry, now: now)) s"
        case .error(let failure, let retry): return "\(message(failure)) • nova tentativa em \(seconds(until: retry, now: now)) s"
        }
    }

    static func message(_ failure: ConnectionFailure) -> String {
        switch failure {
        case .invalidKey: return "Erro: chave local inválida"
        case .connectionRefused: return "Erro: conexão recusada (outro app pode estar conectado)"
        case .localNetworkDenied: return "Permissão de Rede Local necessária"
        case .unsupportedProtocol: return "Erro: protocolo não suportado"
        }
    }

    static func seconds(until date: Date, now: Date) -> Int { max(0, Int(date.timeIntervalSince(now).rounded(.up))) }

    static func dotColor(_ status: ConnectionStatus, powered: Bool = true) -> Color {
        switch status {
        case .connected: return powered ? Theme.green : Theme.gray
        case .connecting: return Theme.amber
        case .offline: return .orange
        case .error: return Theme.red
        case .idle: return Theme.gray
        }
    }

    /// Kelvin label from the mockup: ≤3100 Quente, ≥5200 Frio, otherwise Neutro.
    static func kelvinLabel(_ kelvin: Int) -> String {
        if kelvin <= 3100 { return "Quente" }
        if kelvin >= 5200 { return "Frio" }
        return "Neutro"
    }
}
