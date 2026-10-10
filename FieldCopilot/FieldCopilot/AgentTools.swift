import Foundation
import FoundationModels

// MARK: - Tool activity (what the chat shows)

/// One tool invocation made by the agent while answering, recorded so the
/// chat can show a "the agent used a tool" card above the answer.
struct ToolActivity: Sendable, Identifiable, Hashable {
    let id = UUID()
    /// Card title, e.g. "Refrigerant calculator".
    let title: String
    /// The inputs the model passed, e.g. "R-410A · 118 psig · 43°F line".
    let inputs: String
    /// The computed headline, e.g. "Superheat 3.2°F".
    let result: String
}

/// Collects tool calls during one answer. Tools run on the framework's
/// executor, so this is lock-protected rather than actor-isolated (the
/// tool `call` and the MLX dispatch closure are both synchronous to it).
final class ToolCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ToolActivity] = []
    private let onCall: (@Sendable (ToolActivity) -> Void)?

    init(onCall: (@Sendable (ToolActivity) -> Void)? = nil) {
        self.onCall = onCall
    }

    func record(_ activity: ToolActivity) {
        // A retried generation can repeat the same call; show it once.
        let isNew = lock.withLock {
            guard !items.contains(where: { $0.inputs == activity.inputs && $0.result == activity.result }) else { return false }
            items.append(activity)
            return true
        }
        if isNew { onCall?(activity) }
    }

    var all: [ToolActivity] { lock.withLock { items } }
}

// MARK: - Refrigerant calculator (deterministic)

private func f1(_ v: Double) -> String { String(format: "%.1f", v) }
private func range(_ lo: Double, _ hi: Double) -> String {
    let f = { (v: Double) in v == v.rounded() ? String(Int(v)) : f1(v) }
    return lo == hi ? "\(f(lo))°F" : "\(f(lo))-\(f(hi))°F"
}

/// Superheat / subcooling / saturation math against real pressure-temperature
/// data. Small on-device models cannot do PT-chart lookups reliably, so the
/// agent is given this as a tool and told never to estimate these itself.
enum RefrigerantCalculator {
    enum Calculation: String, CaseIterable, Sendable {
        case superheat, subcooling, saturation
    }

    struct Result: Sendable {
        let calculation: Calculation
        let refrigerant: String
        let pressurePsig: Double
        let saturationTempF: Double
        let lineTempF: Double?
        /// Superheat or subcooling in °F; nil for a plain saturation lookup.
        let value: Double?
        /// Target range from the manual, as the model read it.
        var targetMinF: Double? = nil
        var targetMaxF: Double? = nil

        /// Deterministic comparison against the target. Small models misjudge
        /// "is 3.2 inside 8-12?" (observed: "3.2°F is within 8 to 12°F, no
        /// action needed"), so the tool states the verdict outright.
        var verdict: Verdict? {
            guard let value, let lo = targetMinF ?? targetMaxF, let hi = targetMaxF ?? targetMinF else { return nil }
            let (low, high) = (min(lo, hi), max(lo, hi))
            if value < low { return .below(low - value, low, high) }
            if value > high { return .above(value - high, low, high) }
            return .within(low, high)
        }

        enum Verdict {
            case within(Double, Double), below(Double, Double, Double), above(Double, Double, Double)

            var short: String {
                switch self {
                case .within(let lo, let hi): "within \(range(lo, hi)) target"
                case .below(let d, let lo, let hi): "\(f1(d))°F BELOW \(range(lo, hi)) target"
                case .above(let d, let lo, let hi): "\(f1(d))°F ABOVE \(range(lo, hi)) target"
                }
            }
        }

        /// Text handed back to the model as the tool output.
        var modelSummary: String {
            let sat = String(format: "%.1f", saturationTempF)
            switch calculation {
            case .saturation:
                return "\(refrigerant) at \(fmt(pressurePsig)) psig: saturation temperature \(sat)°F."
            case .superheat:
                return "\(refrigerant) suction \(fmt(pressurePsig)) psig = \(sat)°F saturation. Suction line \(fmt(lineTempF ?? 0))°F. SUPERHEAT = \(String(format: "%.1f", value ?? 0))°F.\(verdictSentence)"
            case .subcooling:
                return "\(refrigerant) head/liquid \(fmt(pressurePsig)) psig = \(sat)°F saturation. Liquid line \(fmt(lineTempF ?? 0))°F. SUBCOOLING = \(String(format: "%.1f", value ?? 0))°F.\(verdictSentence)"
            }
        }

        private var verdictSentence: String {
            guard let verdict else {
                return " No target range was given; compare against the target range in the sources."
            }
            // A plain sentence the model can repeat as-is: raw "VERDICT:" tags
            // and instructions in tool output got copied into answers verbatim.
            let name = calculation == .superheat ? "Superheat" : "Subcooling"
            let where_: String
            switch verdict {
            case .within(let lo, let hi): where_ = "is within the \(range(lo, hi)) target"
            case .below(let d, let lo, let hi): where_ = "is \(f1(d))°F below the \(range(lo, hi)) target"
            case .above(let d, let lo, let hi): where_ = "is \(f1(d))°F above the \(range(lo, hi)) target"
            }
            return " Result: \(name) of \(f1(value ?? 0))°F \(where_). \(meaningSentence ?? "")"
        }

        /// The textbook reading of an out-of-range value (matching the
        /// AC-5000 manual §6.2-6.3). The model reliably got the direction
        /// wrong on its own, e.g. "low superheat suggests undercharge".
        private var meaningSentence: String? {
            switch (calculation, verdict) {
            case (.superheat, .below?): "Superheat too low: the evaporator is overfed, risking liquid floodback into the compressor."
            case (.superheat, .above?): "Superheat too high: the evaporator is starved, usually an undercharge or a restricted/underfeeding metering device."
            case (.subcooling, .below?): "Subcooling too low: points to an undercharge."
            case (.subcooling, .above?): "Subcooling too high: points to an overcharge or a liquid-line restriction."
            case (.superheat, .within?): "Superheat is in range, so the metering device is feeding correctly."
            case (.subcooling, .within?): "Subcooling is in range, so the refrigerant charge is correct."
            default: nil
            }
        }

        var activity: ToolActivity {
            let line = lineTempF.map { " · \(fmt($0))°F line" } ?? ""
            let headline: String
            switch calculation {
            case .saturation: headline = "Saturation \(String(format: "%.1f", saturationTempF))°F"
            case .superheat: headline = "Superheat \(String(format: "%.1f", value ?? 0))°F"
            case .subcooling: headline = "Subcooling \(String(format: "%.1f", value ?? 0))°F"
            }
            let verdictLine = verdict.map { " · \($0.short)" } ?? ""
            return ToolActivity(
                title: "Refrigerant calculator",
                inputs: "\(refrigerant) · \(fmt(pressurePsig)) psig → \(String(format: "%.1f", saturationTempF))°F sat\(line)",
                result: headline + verdictLine)
        }

        private func fmt(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
    }

    enum CalcError: LocalizedError {
        case unknownRefrigerant(String)
        case outOfRange(Double)
        case missingLineTemperature(Calculation)

        var errorDescription: String? {
            switch self {
            case .unknownRefrigerant(let r):
                "Unsupported refrigerant '\(r)'. Supported: \(RefrigerantCalculator.supported.joined(separator: ", "))."
            case .outOfRange(let p):
                "Pressure \(p) psig is outside the PT table (-40°F to 160°F saturation)."
            case .missingLineTemperature(let c):
                "\(c.rawValue) needs a line temperature in °F."
            }
        }
    }

    static let supported = ["R-410A", "R-22", "R-32", "R-134a"]

    /// Parses the target the model copied from the manual: "8 to 12",
    /// "10-14°F", "12". A single value (a nameplate figure) gets ±2°F.
    /// One text field is used because the small model reliably filled only
    /// one of two separate min/max number fields.
    static func parseTarget(_ text: String?) -> (Double, Double)? {
        guard let text else { return nil }
        let nums = text.split(whereSeparator: { !($0.isNumber || $0 == ".") }).compactMap { Double($0) }
        switch nums.count {
        case 0: return nil
        case 1: return (nums[0] - 2, nums[0] + 2)
        default: return (min(nums[0], nums[1]), max(nums[0], nums[1]))
        }
    }

    static func compute(calculation: String, refrigerant: String, pressurePsig: Double,
                        lineTemperatureF: Double?, targetRange: String? = nil) throws -> Result {
        let target = parseTarget(targetRange)
        let targetMinF = target?.0, targetMaxF = target?.1
        var calc = Calculation(rawValue: calculation.lowercased()) ?? .saturation
        let (name, table) = try lookup(refrigerant)
        let sat = try saturationTemperature(psig: pressurePsig, table: table)
        // Physics beats the model's label: a line warmer than saturation is
        // superheated vapor, colder is subcooled liquid. Small models often
        // ask for "superheat" on a liquid-line reading (→ a nonsense negative
        // superheat), so the reading decides which number is meaningful.
        if calc != .saturation, let line = lineTemperatureF {
            calc = line >= sat ? .superheat : .subcooling
        }
        var value: Double?
        switch calc {
        case .saturation:
            break
        case .superheat:
            guard let line = lineTemperatureF else { throw CalcError.missingLineTemperature(calc) }
            value = line - sat
        case .subcooling:
            guard let line = lineTemperatureF else { throw CalcError.missingLineTemperature(calc) }
            value = sat - line
        }
        return Result(calculation: calc, refrigerant: name, pressurePsig: pressurePsig,
                      saturationTempF: sat, lineTempF: lineTemperatureF, value: value,
                      targetMinF: targetMinF, targetMaxF: targetMaxF)
    }

    /// Accepts "R410A", "r-410a", "410A", "Puron"…; blank defaults to R-410A,
    /// the refrigerant in every demo unit.
    private static func lookup(_ raw: String) throws -> (String, [Double]) {
        let key = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "", "R410A", "410A", "PURON": return ("R-410A", PTTable.r410A)
        case "R22", "22", "HCFC22": return ("R-22", PTTable.r22)
        case "R32", "32", "HFC32": return ("R-32", PTTable.r32)
        case "R134A", "134A", "HFC134A": return ("R-134a", PTTable.r134a)
        default: throw CalcError.unknownRefrigerant(raw)
        }
    }

    /// Linear interpolation over the 5°F-step table (error under 0.3°F).
    private static func saturationTemperature(psig: Double, table: [Double]) throws -> Double {
        guard let first = table.first, let last = table.last, psig >= first, psig <= last else {
            throw CalcError.outOfRange(psig)
        }
        for i in 1..<table.count where psig <= table[i] {
            let t0 = PTTable.startF + Double(i - 1) * PTTable.stepF
            let frac = (psig - table[i - 1]) / (table[i] - table[i - 1])
            return t0 + frac * PTTable.stepF
        }
        return PTTable.startF + Double(table.count - 1) * PTTable.stepF
    }
}

/// Saturation pressures (psig) from -40°F to 160°F in 5°F steps.
private enum PTTable {
    static let startF = -40.0
    static let stepF = 5.0

    // Generated with CoolProp 8.0.0 (saturated vapor, Q=1). These four are
    // pure or near-azeotropic (R-410A glide < 0.2°F), so one curve serves
    // both superheat and subcooling.
    static let r410A: [Double] = [
        10.7, 14.0, 17.7, 21.8, 26.2, 31.0, 36.3, 42.0, 48.2,
        54.9, 62.2, 70.0, 78.4, 87.4, 97.0, 107.3, 118.4, 130.1,
        142.6, 156.0, 170.1, 185.1, 201.1, 217.9, 235.7, 254.6, 274.5,
        295.4, 317.6, 340.8, 365.4, 391.2, 418.3, 446.8, 476.8, 508.4,
        541.5, 576.3, 613.0, 651.7, 692.6,
    ]
    static let r22: [Double] = [
        0.6, 2.6, 4.9, 7.4, 10.2, 13.2, 16.5, 20.1, 24.0,
        28.3, 32.8, 37.8, 43.1, 48.8, 55.0, 61.5, 68.6, 76.1,
        84.1, 92.6, 101.6, 111.2, 121.4, 132.2, 143.6, 155.7, 168.4,
        181.8, 195.9, 210.8, 226.4, 242.8, 260.0, 278.0, 296.9, 316.7,
        337.4, 359.0, 381.7, 405.3, 430.1,
    ]
    static let r32: [Double] = [
        11.0, 14.4, 18.2, 22.3, 26.8, 31.7, 37.1, 42.9, 49.3,
        56.1, 63.5, 71.4, 80.0, 89.2, 99.1, 109.7, 121.0, 133.0,
        145.8, 159.5, 174.0, 189.5, 205.8, 223.2, 241.5, 260.9, 281.3,
        302.9, 325.7, 349.6, 374.9, 401.4, 429.3, 458.7, 489.5, 521.8,
        555.8, 591.4, 628.8, 668.1, 709.4,
    ]
    static let r134a: [Double] = [
        -7.3, -6.1, -4.8, -3.4, -1.8, 0.0, 1.9, 4.1, 6.5,
        9.1, 11.9, 15.0, 18.4, 22.1, 26.1, 30.4, 35.0, 40.1,
        45.4, 51.2, 57.4, 64.0, 71.1, 78.7, 86.7, 95.2, 104.3,
        113.9, 124.2, 135.0, 146.4, 158.4, 171.2, 184.6, 198.7, 213.6,
        229.2, 245.7, 262.9, 281.0, 300.0,
    ]
}

// MARK: - Tool definitions per backend

enum AgentTools {
    static let calculatorName = "refrigerantCalculator"
    /// Whether a message carries a gauge reading the calculator could use.
    /// The Foundation model only gets the tool for such messages: offered
    /// on every question, the on-device daemon can stall on long RAG prompts
    /// that don't need it (observed on macOS 27 / iOS 27).
    static func hasPressureReading(_ text: String) -> Bool {
        text.range(of: #"\d+(\.\d+)?\s*(psig|psi|lb)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static let calculatorDescription = """
    Computes refrigerant superheat, subcooling, or saturation temperature from a gauge pressure \
    (psig) and a line temperature (°F) using real pressure-temperature data. ALWAYS use this for \
    any superheat, subcooling, or saturation question - never estimate these yourself.
    """

    /// Shared by every backend so all of them log and report identically.
    static func runCalculator(calculation: String, refrigerant: String, pressurePsig: Double,
                              lineTemperatureF: Double?, targetRange: String? = nil,
                              log: ToolCallLog) -> String {
        do {
            let result = try RefrigerantCalculator.compute(
                calculation: calculation, refrigerant: refrigerant,
                pressurePsig: pressurePsig, lineTemperatureF: lineTemperatureF,
                targetRange: targetRange)
            log.record(result.activity)
            print("[AgentTools] \(result.modelSummary)")
            return result.modelSummary
        } catch {
            print("[AgentTools] Calculator error: \(error.localizedDescription)")
            return "Calculator error: \(error.localizedDescription)"
        }
    }

    // Apple Foundation model: native `Tool`.
    struct RefrigerantCalculatorTool: Tool {
        let log: ToolCallLog
        let name = AgentTools.calculatorName
        let description = AgentTools.calculatorDescription

        @Generable
        struct Arguments {
            @Guide(description: "superheat (suction pressure + suction line temperature), subcooling (head/liquid pressure + liquid line temperature), or saturation (pressure only)",
                   .anyOf(["superheat", "subcooling", "saturation"]))
            var calculation: String
            @Guide(description: "Refrigerant, e.g. R-410A. Use the unit's refrigerant from the work order; R-410A if unknown.")
            var refrigerant: String
            @Guide(description: "Gauge pressure in psig")
            var pressurePsig: Double
            @Guide(description: "Measured line temperature in °F (suction line for superheat, liquid line for subcooling). 0 for a saturation lookup.")
            var lineTemperatureF: Double
            @Guide(description: "The target range for this value copied from the manual sources, both ends, e.g. '8 to 12' for '8 to 12°F superheat'. Empty string if the sources give none.")
            var targetRange: String
        }

        func call(arguments: Arguments) async throws -> String {
            AgentTools.runCalculator(
                calculation: arguments.calculation, refrigerant: arguments.refrigerant,
                pressurePsig: arguments.pressurePsig,
                lineTemperatureF: arguments.calculation == "saturation" ? nil : arguments.lineTemperatureF,
                targetRange: arguments.targetRange,
                log: log)
        }
    }

    // MLX (Qwen) and OpenAI: OpenAI-style JSON function schema.
    static let calculatorSchema: [String: any Sendable] = [
        "type": "function",
        "function": [
            "name": calculatorName,
            "description": calculatorDescription,
            "parameters": [
                "type": "object",
                "properties": [
                    "calculation": [
                        "type": "string",
                        "enum": ["superheat", "subcooling", "saturation"],
                        "description": "superheat (suction pressure + suction line temp), subcooling (head/liquid pressure + liquid line temp), or saturation (pressure only)",
                    ] as [String: any Sendable],
                    "refrigerant": [
                        "type": "string",
                        "description": "Refrigerant, e.g. R-410A. Use the unit's refrigerant; R-410A if unknown.",
                    ] as [String: any Sendable],
                    "pressurePsig": ["type": "number", "description": "Gauge pressure in psig"] as [String: any Sendable],
                    "lineTemperatureF": ["type": "number", "description": "Measured line temperature in °F"] as [String: any Sendable],
                    "targetRange": ["type": "string", "description": "Target range for this value copied from the manual, both ends, e.g. '8 to 12'"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["calculation", "refrigerant", "pressurePsig"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    /// Dispatches a JSON-arguments tool call (MLX or OpenAI) by name.
    static func dispatch(name: String, arguments: [String: Any], log: ToolCallLog) -> String {
        guard name == calculatorName else { return "Unknown tool '\(name)'." }
        func number(_ key: String) -> Double? {
            switch arguments[key] {
            case let d as Double: d
            case let i as Int: Double(i)
            case let n as NSNumber: n.doubleValue
            case let s as String: Double(s.filter { $0.isNumber || $0 == "." || $0 == "-" })
            default: nil
            }
        }
        guard let pressure = number("pressurePsig") else {
            return "Calculator error: pressurePsig is required."
        }
        return runCalculator(
            calculation: arguments["calculation"] as? String ?? "saturation",
            refrigerant: arguments["refrigerant"] as? String ?? "R-410A",
            pressurePsig: pressure,
            lineTemperatureF: number("lineTemperatureF"),
            targetRange: arguments["targetRange"].map { "\($0)" },
            log: log)
    }
}
