import ActivityKit
import SwiftUI
import WidgetKit

// Live Activity UI must be SwiftUI; colours repeat the app's tokens (App/Design/Theme.swift).
private enum ActivityColor {
  static let working = Color(red: 0xea / 255, green: 0xb3 / 255, blue: 0x08 / 255)
  static let attention = Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255)
  static let done = Color(red: 0x10 / 255, green: 0xb9 / 255, blue: 0x81 / 255)
  static let primary = Color(red: 0xfa / 255, green: 0xfa / 255, blue: 0xfa / 255)
  static let secondary = Color(red: 0xac / 255, green: 0xac / 255, blue: 0xac / 255)
  static let ground = Color(red: 0x0a / 255, green: 0x0a / 255, blue: 0x0a / 255)

  /// Waiting on the person: orange, apart from a failure's red.
  static let needsYou = Color(red: 0xf9 / 255, green: 0x73 / 255, blue: 0x16 / 255)

  static func tint(_ phase: AgentActivityAttributes.Phase) -> Color {
    switch phase {
    case .working: working
    case .needsYou: needsYou
    case .failed: attention
    case .done: done
    }
  }
}

private extension AgentActivityAttributes.Phase {
  var label: String {
    switch self {
    case .working: String(localized: "Working")
    case .needsYou: String(localized: "Needs you")
    case .done: String(localized: "Done")
    case .failed: String(localized: "Failed")
    }
  }
}

/// The island's indicator light: one glowing dot in the state's colour (green done or idle, orange needs
/// you, red failed, amber working); while working it breathes.
private struct StatusLight: View {
  let phase: AgentActivityAttributes.Phase
  var size: CGFloat = 9

  var body: some View {
    let tint = ActivityColor.tint(phase)
    Circle()
      .fill(tint)
      .frame(width: size, height: size)
      .shadow(color: tint.opacity(0.9), radius: 3)
      .shadow(color: tint.opacity(0.5), radius: 6)
      .modifier(Breathing(active: phase == .working))
      .frame(width: size + 8, height: size + 8)
      .accessibilityLabel(phase.label)
  }
}

/// A slow fade between bright and dim, for a light that is busy.
private struct Breathing: ViewModifier {
  let active: Bool

  func body(content: Content) -> some View {
    if active {
      content.phaseAnimator([1.0, 0.35]) { view, opacity in view.opacity(opacity) } animation: { _ in
        .easeInOut(duration: 0.9)
      }
    } else {
      content
    }
  }
}

private struct Elapsed: View {
  let state: AgentActivityAttributes.ContentState

  var body: some View {
    if state.phase == .working {
      Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
        .monospacedDigit()
    } else {
      Text(state.since, style: .relative)
    }
  }
}

private struct LockScreenView: View {
  let context: ActivityViewContext<AgentActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        StatusLight(phase: context.state.phase, size: 8)
        Text(context.attributes.workspaceName)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(ActivityColor.primary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Elapsed(state: context.state)
          .font(.system(size: 12))
          .foregroundStyle(ActivityColor.secondary)
          .frame(maxWidth: 64, alignment: .trailing)
      }
      Text(context.state.detail)
        .font(.system(size: 14))
        .foregroundStyle(ActivityColor.primary.opacity(0.9))
        .lineLimit(2)
      HStack(spacing: 6) {
        Text(context.state.phase.label)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(ActivityColor.tint(context.state.phase))
        Text("·").foregroundStyle(ActivityColor.secondary)
        Text("\(context.attributes.agentName) on \(context.attributes.hostName)")
          .font(.system(size: 12))
          .foregroundStyle(ActivityColor.secondary)
          .lineLimit(1)
      }
    }
    .padding(16)
    .activityBackgroundTint(ActivityColor.ground)
    .activitySystemActionForegroundColor(ActivityColor.primary)
    .widgetURL(context.attributes.deepLink)
  }
}

struct AgentLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AgentActivityAttributes.self) { context in
      LockScreenView(context: context)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            StatusLight(phase: context.state.phase, size: 8)
            Text(context.attributes.agentName)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)
          }
          .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Elapsed(state: context.state)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 70, alignment: .trailing)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 4) {
            Text(context.attributes.workspaceName)
              .font(.system(size: 15, weight: .semibold))
              .lineLimit(1)
            Text(context.state.detail)
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
        }
      } compactLeading: {
        // The island says the state with a light, nothing more.
        StatusLight(phase: context.state.phase)
      } compactTrailing: {
        EmptyView()
      } minimal: {
        StatusLight(phase: context.state.phase)
      }
      .widgetURL(context.attributes.deepLink)
      .keylineTint(ActivityColor.tint(context.state.phase))
    }
  }
}

@main
struct OrcaWidgets: WidgetBundle {
  var body: some Widget {
    AgentLiveActivity()
  }
}
