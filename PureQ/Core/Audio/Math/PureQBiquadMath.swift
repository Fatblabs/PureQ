//
//  PureQBiquadMath.swift
//  PureQ
//

import Foundation

struct PureQBiquadCoefficients: Equatable {
    static let identity = PureQBiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    var isUsable: Bool {
        b0.isFinite && b1.isFinite && b2.isFinite && a1.isFinite && a2.isFinite
    }

    func magnitudeDecibels(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        return magnitudeDecibels(
            cos1: cos(omega),
            sin1: sin(omega),
            cos2: cos(2 * omega),
            sin2: sin(2 * omega)
        )
    }

    func magnitudeDecibels(cos1: Double, sin1: Double, cos2: Double, sin2: Double) -> Double {
        let numeratorReal = b0 + (b1 * cos1) + (b2 * cos2)
        let numeratorImaginary = (-b1 * sin1) - (b2 * sin2)
        let denominatorReal = 1 + (a1 * cos1) + (a2 * cos2)
        let denominatorImaginary = (-a1 * sin1) - (a2 * sin2)

        let numeratorPower = (numeratorReal * numeratorReal) + (numeratorImaginary * numeratorImaginary)
        let denominatorPower = max((denominatorReal * denominatorReal) + (denominatorImaginary * denominatorImaginary), 1e-24)
        let magnitude = sqrt(max(numeratorPower / denominatorPower, 1e-24))
        return 20 * log10(magnitude)
    }
}

enum PureQBiquadMath {
    static func coefficients(for descriptor: AudioEngineFilterDescriptor, sampleRate: Double) -> PureQBiquadCoefficients? {
        coefficients(
            shape: descriptor.shape,
            sampleRate: sampleRate,
            frequency: descriptor.frequency,
            q: descriptor.q,
            gain: descriptor.gain
        )
    }

    static func coefficients(
        shape: BandShape,
        sampleRate: Double,
        frequency: Double,
        q: Double,
        gain: Double
    ) -> PureQBiquadCoefficients? {
        let rate = sampleRate.clamped(to: 8_000...384_000)
        let resolvedFrequency = frequency.clamped(to: 1...(rate * 0.49))
        let resolvedQ = q.clamped(to: 0.1...100)
        let resolvedGain = gain.clamped(to: -36...36)

        let omega = 2 * Double.pi * resolvedFrequency / rate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * resolvedQ)
        let amplitude = pow(10, resolvedGain / 40)

        let raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)
        switch shape {
        case .bell:
            raw = (
                b0: 1 + (alpha * amplitude),
                b1: -2 * cosOmega,
                b2: 1 - (alpha * amplitude),
                a0: 1 + (alpha / amplitude),
                a1: -2 * cosOmega,
                a2: 1 - (alpha / amplitude)
            )
        case .shelf where resolvedFrequency < 1_000:
            raw = lowShelf(amplitude: amplitude, sinOmega: sinOmega, cosOmega: cosOmega, alpha: alpha)
        case .shelf:
            raw = highShelf(amplitude: amplitude, sinOmega: sinOmega, cosOmega: cosOmega, alpha: alpha)
        case .notch:
            raw = (
                b0: 1,
                b1: -2 * cosOmega,
                b2: 1,
                a0: 1 + alpha,
                a1: -2 * cosOmega,
                a2: 1 - alpha
            )
        }

        return normalized(raw)
    }

    private static func lowShelf(
        amplitude: Double,
        sinOmega: Double,
        cosOmega: Double,
        alpha: Double
    ) -> (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        let twoSqrtAAlpha = 2 * sqrt(amplitude) * alpha
        return (
            b0: amplitude * ((amplitude + 1) - ((amplitude - 1) * cosOmega) + twoSqrtAAlpha),
            b1: 2 * amplitude * ((amplitude - 1) - ((amplitude + 1) * cosOmega)),
            b2: amplitude * ((amplitude + 1) - ((amplitude - 1) * cosOmega) - twoSqrtAAlpha),
            a0: (amplitude + 1) + ((amplitude - 1) * cosOmega) + twoSqrtAAlpha,
            a1: -2 * ((amplitude - 1) + ((amplitude + 1) * cosOmega)),
            a2: (amplitude + 1) + ((amplitude - 1) * cosOmega) - twoSqrtAAlpha
        )
    }

    private static func highShelf(
        amplitude: Double,
        sinOmega: Double,
        cosOmega: Double,
        alpha: Double
    ) -> (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        let twoSqrtAAlpha = 2 * sqrt(amplitude) * alpha
        return (
            b0: amplitude * ((amplitude + 1) + ((amplitude - 1) * cosOmega) + twoSqrtAAlpha),
            b1: -2 * amplitude * ((amplitude - 1) + ((amplitude + 1) * cosOmega)),
            b2: amplitude * ((amplitude + 1) + ((amplitude - 1) * cosOmega) - twoSqrtAAlpha),
            a0: (amplitude + 1) - ((amplitude - 1) * cosOmega) + twoSqrtAAlpha,
            a1: 2 * ((amplitude - 1) - ((amplitude + 1) * cosOmega)),
            a2: (amplitude + 1) - ((amplitude - 1) * cosOmega) - twoSqrtAAlpha
        )
    }

    private static func normalized(
        _ raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)
    ) -> PureQBiquadCoefficients? {
        guard raw.a0.isFinite, abs(raw.a0) > .ulpOfOne else { return nil }
        let inverseA0 = 1 / raw.a0
        let coefficients = PureQBiquadCoefficients(
            b0: raw.b0 * inverseA0,
            b1: raw.b1 * inverseA0,
            b2: raw.b2 * inverseA0,
            a1: raw.a1 * inverseA0,
            a2: raw.a2 * inverseA0
        )
        return coefficients.isUsable ? coefficients : nil
    }
}
