# OBDiag — Design Overview

**OBDiag** is an AI-powered vehicle diagnostics app for iPhone and iPad. It connects to a Bluetooth OBD-II adapter, reads live data and fault codes directly from the car, and pairs that with an AI diagnostic assistant that explains problems, recommends fixes, and points to parts and repair resources.

The guiding idea: a car owner should be able to plug in a cheap OBD-II adapter, open the app, and get a plain-language answer to "what's wrong with my car, and what should I do about it?"

---

## Core Concepts

- **Garage** — the user's collection of vehicles. Everything in the app (live data, fault codes, chat) is scoped to one vehicle at a time.
- **Vehicle context** — year, make, model, trim, and optionally VIN. This context is fed to the AI so its advice is specific to the actual car, not generic.
- **Diagnostic session** — connecting to the adapter, viewing live sensors, reading/clearing fault codes, and asking the AI about them.
- **AI assistant** — a streaming chat assistant with access to live vehicle data, web search, video search, parts search, and URL reading. It cites sources and can ask the user clarifying multiple-choice questions.
- **Credits & subscriptions** — AI usage is metered in credits, with subscription tiers that grant different credit allowances and model quality levels.

---

## Features

### Garage (Home)
- List of saved vehicles with connection status and fault-code counts.
- Add, edit, and remove vehicles.
- Empty state guides first-time users; a generic "Direct OBD Connection" option lets users skip vehicle setup entirely.
- A global banner shows the live OBD connection status across the app.

### Add Vehicle
- Vehicle lookup by year / make / model / trim using a public vehicle database.
- VIN entry with decode, or VIN read directly from the car over OBD.
- A guided, multi-step flow that confirms details before adding to the garage.

### Onboarding
- First-run questionnaire covering garage size, vehicle age, discovery source, goals, and experience level.
- The flow adapts based on answers and walks new users through adding their first vehicle.
- Optional subscription upsell during onboarding, with yearly pricing presented as the recommended option.

### Vehicle Dashboard
- Connect to an OBD-II adapter over Bluetooth: scan for nearby devices, connect, disconnect, and see connection state.
- A demo mode that simulates a connected vehicle for exploring the app without hardware.
- Live sensor dashboard: RPM, speed, coolant temperature, throttle, engine load, battery voltage, intake air temperature, MAF, fuel trims, O2 sensors, and more. Readings update continuously and are color-coded by severity.
- Fault codes (DTCs): read stored, pending, and permanent codes, view descriptions and severity, and clear codes with confirmation.
- Automatic vehicle detection: if the adapter reports a VIN that doesn't match the current vehicle, the app offers to decode it and create/switch the vehicle.
- A raw OBD debug log for troubleshooting connection and protocol issues.
- Metric/imperial unit preferences throughout.

### AI Diagnostic Chat
- Streaming chat interface scoped to the currently selected vehicle.
- The assistant automatically uses vehicle details, active fault codes, and live sensor data as context.
- Tool use while answering:
  - Read live OBD data and fault codes on demand.
  - Web search for facts, recalls, TSBs, specs, and procedures.
  - Repair video search for DIY walkthroughs.
  - Parts & tools search for purchase recommendations.
  - URL reading to pull details from repair guides, forums, and listings.
  - Ask-the-user questionnaires when missing information blocks a reliable answer.
- Answers are structured for action: what it means, likely causes, diagnostic steps, parts to buy, tools needed, and videos to watch.
- Citation of sources with tappable references, source previews, and rich link pills.
- Conversation history per vehicle, with new/rename/delete conversations and a history sidebar.
- In-chat model picker, showing model capability/cost tiers and letting the user switch models mid-session.
- Reasoning ("thinking") content is handled and displayed appropriately while the model works.

### Settings
- AI provider configuration: OpenRouter API key (stored securely) or a local model server (LM Studio).
- Model selection with intelligence/cost tier indicators; simplified speed tiers (Flash / Plus / Max) for regular users.
- Subscription management: current plan, credit balance, plan comparison, and in-app purchase with monthly/yearly billing.
- Unit preferences (imperial vs. metric).
- Data management: reset onboarding, reset all app data.

### Platform & Behavior
- Native iOS/iPadOS app (SwiftUI), adaptive layout for phone and tablet.
- Dark, automotive-themed visual design with consistent theming.
- Local persistence of garage, conversations, and settings; all data stays on-device.
- Demo/simulated mode so the full experience can be evaluated without a physical adapter.

---

## Design Principles

- **Action over information** — every diagnostic answer should end with something the user can actually do.
- **Verify, don't guess** — the assistant is directed to prefer sources, cite them, and ask the user when a fact can't be confirmed.
- **Vehicle-specific** — all advice is framed around the selected vehicle's data, codes, and live readings.
- **Approachable** — plain-language explanations for beginners, without hiding detail from experienced users.
- **Graceful degradation** — the app is useful with no adapter (history, chat), more useful with one (live data, codes), and best when both hardware and AI are available.

utilize liquid glass and apples HIG 
https://developer.apple.com/documentation/technologyoverviews/liquid-glass
https://developer.apple.com/design/human-interface-guidelines/designing-for-ios