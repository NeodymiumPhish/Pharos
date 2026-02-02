# Pharos iPad App UI Design Strategy

## Executive Summary

This document outlines the strategy for developing an iPad-native version of Pharos, the PostgreSQL database client. The iPad app will feature two primary interfaces optimized for touch interaction and the larger iPad display:

1. **Query Interface** - Database exploration, saved queries, and query editing
2. **Results Interface** - Full-screen results with collapsible query sidebar

---

## Technology Stack Recommendations

### Recommended Approach: React Native with Expo

| Technology | Purpose | Rationale |
|------------|---------|-----------|
| **React Native** | UI Framework | Leverages existing React/TypeScript expertise from web codebase |
| **Expo** | Build & Development | Simplified iOS builds, OTA updates, native module management |
| **TypeScript** | Language | Maintains consistency with existing codebase |
| **Zustand** | State Management | Direct port from existing stores with minimal changes |
| **React Navigation** | Navigation | Native iOS navigation patterns, tab-based routing |
| **expo-sqlite** | Local Storage | Saved queries, connection configs, settings |
| **react-native-postgres** | PostgreSQL | Direct database connectivity |
| **@shopify/flash-list** | Virtualized Lists | High-performance results grid rendering |

### Alternative Consideration: SwiftUI Native

For maximum iOS integration and performance, a native SwiftUI implementation could be considered. However, this would require:
- Complete rewrite of UI components
- New team expertise in Swift/SwiftUI
- Separate codebase maintenance

**Recommendation**: Start with React Native to maximize code reuse, with potential SwiftUI migration for v2 if native performance becomes critical.

### Code Reuse Strategy

From the existing Pharos codebase, the following can be directly reused:

| Module | Reuse Level | Notes |
|--------|-------------|-------|
| `stores/*.ts` | 90% | Zustand stores work directly in React Native |
| `lib/types.ts` | 100% | TypeScript interfaces are platform-agnostic |
| SQL validation logic | 100% | Pure TypeScript functions |
| Theme system | 70% | CSS variables → React Native StyleSheet |
| Monaco Editor | 0% | Replace with `react-native-code-editor` |

---

## Interface Architecture

### Interface 1: Query Interface (Primary Workspace)

This interface focuses on database exploration and query authoring.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  [≡] Pharos                    [Connection ▼]              [⚙] [👤]    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────┐  ┌────────────────────────────────────────────┐  │
│  │  SIDEBAR (320pt) │  │  MAIN CONTENT AREA                         │  │
│  │                  │  │                                            │  │
│  │  ┌────────────┐  │  │  ┌─────────────────────────────────────┐  │  │
│  │  │ 🔍 Search  │  │  │  │  [Tab1] [Tab2] [Tab3+]       [+ ]   │  │  │
│  │  └────────────┘  │  │  └─────────────────────────────────────┘  │  │
│  │                  │  │                                            │  │
│  │  ▼ CONNECTIONS   │  │  ┌─────────────────────────────────────┐  │  │
│  │    ● Production  │  │  │                                     │  │  │
│  │    ○ Staging     │  │  │                                     │  │  │
│  │    ○ Local Dev   │  │  │         QUERY EDITOR                │  │  │
│  │                  │  │  │                                     │  │  │
│  │  ▼ SCHEMAS       │  │  │    SELECT * FROM users              │  │  │
│  │    ▶ public      │  │  │    WHERE active = true              │  │  │
│  │    ▶ analytics   │  │  │    ORDER BY created_at DESC         │  │  │
│  │                  │  │  │    LIMIT 100;                       │  │  │
│  │  ▼ TABLES        │  │  │                                     │  │  │
│  │    📋 users      │  │  │                                     │  │  │
│  │    📋 orders     │  │  │                                     │  │  │
│  │    📋 products   │  │  └─────────────────────────────────────┘  │  │
│  │    📋 sessions   │  │                                            │  │
│  │                  │  │  ┌─────────────────────────────────────┐  │  │
│  │  ▼ SAVED QUERIES │  │  │  ▶ Run  │  💾 Save  │  ⎘ Format     │  │  │
│  │    📁 Reports    │  │  └─────────────────────────────────────┘  │  │
│  │      └─ Daily    │  │                                            │  │
│  │      └─ Weekly   │  │  ┌─────────────────────────────────────┐  │  │
│  │    📄 User count │  │  │  RESULTS PREVIEW (collapsible)      │  │  │
│  │    📄 Revenue    │  │  │  ────────────────────────────────── │  │  │
│  │                  │  │  │  id │ name     │ email              │  │  │
│  │                  │  │  │  1  │ Alice    │ alice@...          │  │  │
│  │                  │  │  │  2  │ Bob      │ bob@...            │  │  │
│  │                  │  │  │                                     │  │  │
│  │                  │  │  │     [Expand Results →]              │  │  │
│  │                  │  │  └─────────────────────────────────────┘  │  │
│  │                  │  │                                            │  │
│  └──────────────────┘  └────────────────────────────────────────────┘  │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│  [Query]                                              [Results]         │
│     ●                                                    ○              │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Sidebar Components (Left Panel)

| Section | Functionality | Touch Interactions |
|---------|--------------|-------------------|
| **Search** | Global search across tables, columns, saved queries | Tap to focus, keyboard appears |
| **Connections** | List all configured database connections | Tap to select, long-press for options |
| **Schemas** | Expandable schema tree | Tap to expand/collapse |
| **Tables** | Tables within selected schema | Tap to view columns, long-press to insert name |
| **Saved Queries** | Folder-organized saved queries | Tap to load, swipe to delete, drag to reorder |

#### Main Content Area

| Component | Functionality | Touch Interactions |
|-----------|--------------|-------------------|
| **Query Tabs** | Multiple concurrent queries | Swipe to switch, tap to select, swipe-down to close |
| **Query Editor** | SQL text editing | Native iOS keyboard, selection handles, autocomplete popover |
| **Action Bar** | Run, Save, Format, Clear | Large touch targets (44pt minimum) |
| **Results Preview** | Collapsed results view (3-5 rows) | Tap "Expand" to switch to Results Interface |

---

### Interface 2: Results Interface (Data Focus)

This interface prioritizes viewing and interacting with query results.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  [←] Query    Results: users                    [Export ▼]   [⚙]       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  FULL-WIDTH RESULTS GRID                                        │   │
│  │                                                                  │   │
│  │  ┌────┬──────────────┬─────────────────────┬──────────────────┐│   │
│  │  │ id │ name         │ email               │ created_at       ││   │
│  │  ├────┼──────────────┼─────────────────────┼──────────────────┤│   │
│  │  │ 1  │ Alice Smith  │ alice@example.com   │ 2024-01-15 09:23 ││   │
│  │  │ 2  │ Bob Johnson  │ bob@example.com     │ 2024-01-14 14:45 ││   │
│  │  │ 3  │ Carol White  │ carol@example.com   │ 2024-01-14 11:30 ││   │
│  │  │ 4  │ David Brown  │ david@example.com   │ 2024-01-13 16:20 ││   │
│  │  │ 5  │ Eve Davis    │ eve@example.com     │ 2024-01-13 08:15 ││   │
│  │  │ 6  │ Frank Miller │ frank@example.com   │ 2024-01-12 22:40 ││   │
│  │  │ 7  │ Grace Lee    │ grace@example.com   │ 2024-01-12 17:55 ││   │
│  │  │ 8  │ Henry Wilson │ henry@example.com   │ 2024-01-11 13:10 ││   │
│  │  │ 9  │ Ivy Martinez │ ivy@example.com     │ 2024-01-11 09:30 ││   │
│  │  │ 10 │ Jack Taylor  │ jack@example.com    │ 2024-01-10 15:45 ││   │
│  │  │ .. │ ...          │ ...                 │ ...              ││   │
│  │  └────┴──────────────┴─────────────────────┴──────────────────┘│   │
│  │                                                                  │   │
│  │         (Scroll horizontally for more columns →)                │   │
│  │         (Scroll vertically for more rows ↓)                     │   │
│  │                                                                  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│  1,247 rows │ 8 columns │ 0.045s │ Connected: Production              │
├─────────────────────────────────────────────────────────────────────────┤
│  [Query]                                              [Results]         │
│     ○                                                    ●              │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Query Sidebar (Slide-Out Panel)

When the user needs to edit the query while viewing results, a sidebar slides in from the left:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  [←] Query    Results: users                    [Export ▼]   [⚙]       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────┬──────────────────────────────────────────────┐   │
│  │  QUERY SIDEBAR   │  RESULTS GRID (compressed)                   │   │
│  │  (slide-in 380pt)│                                              │   │
│  │                  │  ┌────┬──────────┬─────────────┬───────────┐ │   │
│  │  ┌────────────┐  │  │ id │ name     │ email       │ created   │ │   │
│  │  │  Tab: Q1   │  │  ├────┼──────────┼─────────────┼───────────┤ │   │
│  │  └────────────┘  │  │ 1  │ Alice    │ alice@...   │ 2024-01.. │ │   │
│  │                  │  │ 2  │ Bob      │ bob@...     │ 2024-01.. │ │   │
│  │  SELECT *        │  │ 3  │ Carol    │ carol@...   │ 2024-01.. │ │   │
│  │  FROM users      │  │ 4  │ David    │ david@...   │ 2024-01.. │ │   │
│  │  WHERE active    │  │ 5  │ Eve      │ eve@...     │ 2024-01.. │ │   │
│  │    = true        │  │ 6  │ Frank    │ frank@...   │ 2024-01.. │ │   │
│  │  ORDER BY        │  │ .. │ ...      │ ...         │ ...       │ │   │
│  │    created_at    │  └────┴──────────┴─────────────┴───────────┘ │   │
│  │    DESC          │                                              │   │
│  │  LIMIT 100;      │         (Scroll for more →↓)                 │   │
│  │                  │                                              │   │
│  │  ──────────────  │                                              │   │
│  │  [▶ Run Query ]  │                                              │   │
│  │  [💾 Save Query] │                                              │   │
│  │  [✕ Close Panel] │                                              │   │
│  │                  │                                              │   │
│  └──────────────────┴──────────────────────────────────────────────┘   │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│  1,247 rows │ 8 columns │ 0.045s │ Connected: Production              │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Results Interface Features

| Feature | Description | Interaction |
|---------|-------------|-------------|
| **Column Resizing** | Drag column borders | Long-press + drag |
| **Column Reordering** | Drag columns to reorder | Long-press header + drag |
| **Cell Selection** | Select individual cells or ranges | Tap for single, drag for range |
| **Copy** | Copy selected cells | Selection → context menu |
| **Export** | CSV, JSON, Clipboard | Export dropdown menu |
| **Sort** | Sort by column | Tap column header |
| **Filter** | Quick column filters | Long-press column header |
| **Query Sidebar** | Edit current query | Swipe right from left edge or tap "← Query" |

---

## Navigation Architecture

### Tab-Based Navigation (Bottom)

```
┌────────────────────────────────────────────────┐
│  [📝 Query]                    [📊 Results]    │
│     ●                             ○            │
└────────────────────────────────────────────────┘
```

The app uses a two-tab bottom navigation system:

| Tab | Primary View | Secondary Access |
|-----|--------------|------------------|
| **Query** | Database explorer + Query editor | Results preview (collapsed) |
| **Results** | Full results grid | Query sidebar (slide-in) |

### Navigation State Flow

```
                    ┌─────────────────────────────────────────┐
                    │              APP LAUNCH                  │
                    └─────────────────┬───────────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────────┐
                    │         CONNECTION SELECTOR              │
                    │   (if no active connection)              │
                    └─────────────────┬───────────────────────┘
                                      │
                                      ▼
          ┌───────────────────────────────────────────────────────────┐
          │                                                           │
          │                    QUERY INTERFACE                        │
          │                                                           │
          │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
          │   │   Browse    │───▶│   Write     │───▶│   Execute   │  │
          │   │   Schema    │    │   Query     │    │   Query     │  │
          │   └─────────────┘    └─────────────┘    └──────┬──────┘  │
          │         ▲                   ▲                   │         │
          │         │                   │                   │         │
          │         └───────────────────┼───────────────────┘         │
          │                             │                             │
          └─────────────────────────────┼─────────────────────────────┘
                                        │
                      ┌─────────────────┴─────────────────┐
                      │                                   │
                      ▼                                   ▼
         ┌─────────────────────────┐     ┌─────────────────────────┐
         │   RESULTS INTERFACE     │     │   EXPAND FROM PREVIEW   │
         │   (via tab switch)      │     │   (within Query view)   │
         └───────────┬─────────────┘     └───────────┬─────────────┘
                     │                               │
                     └───────────────┬───────────────┘
                                     │
                                     ▼
          ┌───────────────────────────────────────────────────────────┐
          │                                                           │
          │                   RESULTS INTERFACE                       │
          │                                                           │
          │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
          │   │   View      │───▶│   Export    │───▶│   Share     │  │
          │   │   Results   │    │   Data      │    │   Query     │  │
          │   └─────────────┘    └─────────────┘    └─────────────┘  │
          │         │                                     │           │
          │         │          ┌─────────────┐            │           │
          │         └─────────▶│   Edit      │◀───────────┘           │
          │                    │   Query     │                        │
          │                    │  (sidebar)  │                        │
          │                    └─────────────┘                        │
          │                                                           │
          └───────────────────────────────────────────────────────────┘
```

---

## Component Architecture

### Core Components

```
src/
├── App.tsx                           # Root with navigation setup
├── navigation/
│   ├── RootNavigator.tsx            # Bottom tab navigator
│   ├── QueryStack.tsx               # Query interface stack
│   └── ResultsStack.tsx             # Results interface stack
│
├── screens/
│   ├── QueryScreen.tsx              # Main query interface
│   ├── ResultsScreen.tsx            # Full results view
│   ├── ConnectionsScreen.tsx        # Connection management
│   └── SettingsScreen.tsx           # App settings
│
├── components/
│   ├── layout/
│   │   ├── SplitView.tsx            # iPad split view container
│   │   ├── SlidingSidebar.tsx       # Animated slide-in panel
│   │   └── BottomTabBar.tsx         # Custom tab bar
│   │
│   ├── database/
│   │   ├── ConnectionList.tsx       # Connection selector
│   │   ├── SchemaTree.tsx           # Schema browser (port from web)
│   │   ├── TableList.tsx            # Table listing
│   │   └── ColumnInfo.tsx           # Column metadata view
│   │
│   ├── editor/
│   │   ├── QueryEditor.tsx          # SQL editor (CodeMirror-based)
│   │   ├── QueryTabs.tsx            # Tab management
│   │   ├── AutoComplete.tsx         # SQL autocomplete popover
│   │   └── ActionBar.tsx            # Run/Save/Format buttons
│   │
│   ├── results/
│   │   ├── ResultsGrid.tsx          # Virtualized data grid
│   │   ├── ResultsHeader.tsx        # Column headers with sort/filter
│   │   ├── ResultsCell.tsx          # Individual cell rendering
│   │   ├── ResultsPreview.tsx       # Collapsed preview (3 rows)
│   │   └── ExportMenu.tsx           # Export options
│   │
│   ├── saved/
│   │   ├── SavedQueriesPanel.tsx    # Saved queries browser
│   │   ├── FolderTree.tsx           # Folder organization
│   │   └── QueryItem.tsx            # Individual query item
│   │
│   └── ui/
│       ├── GlassPanel.tsx           # iOS-style glass morphism
│       ├── SearchBar.tsx            # Search input
│       ├── IconButton.tsx           # Touch-friendly icon button
│       └── StatusBar.tsx            # Connection/execution status
│
├── stores/                          # Zustand stores (port from web)
│   ├── editorStore.ts
│   ├── connectionStore.ts
│   ├── savedQueryStore.ts
│   └── settingsStore.ts
│
├── services/
│   ├── database.ts                  # PostgreSQL connection handling
│   ├── storage.ts                   # Local SQLite for persistence
│   └── export.ts                    # CSV/JSON export utilities
│
├── hooks/
│   ├── useDatabase.ts               # Database connection hook
│   ├── useQuery.ts                  # Query execution hook
│   └── useKeyboard.ts               # Keyboard visibility handling
│
└── lib/
    ├── types.ts                     # Shared types (from web)
    └── theme.ts                     # Theme configuration
```

### Component Hierarchy

```
<App>
├── <NavigationContainer>
│   └── <BottomTabNavigator>
│       │
│       ├── <QueryScreen>                    # Tab 1: Query Interface
│       │   └── <SplitView>
│       │       ├── <Sidebar>                # Left panel (320pt)
│       │       │   ├── <SearchBar />
│       │       │   ├── <ConnectionList />
│       │       │   ├── <SchemaTree />
│       │       │   └── <SavedQueriesPanel />
│       │       │
│       │       └── <MainContent>            # Right panel (flexible)
│       │           ├── <QueryTabs />
│       │           ├── <QueryEditor />
│       │           ├── <ActionBar />
│       │           └── <ResultsPreview />   # Collapsible
│       │
│       └── <ResultsScreen>                  # Tab 2: Results Interface
│           ├── <SlidingSidebar>             # Query sidebar (slide-in)
│           │   ├── <QueryEditor />
│           │   └── <ActionBar />
│           │
│           └── <ResultsGrid />              # Full-width results
│               ├── <ResultsHeader />
│               └── <VirtualizedRows />
│
└── <Modals>
    ├── <ConnectionDialog />
    ├── <SaveQueryDialog />
    └── <SettingsDialog />
```

---

## State Management

### Store Architecture (Zustand)

The existing Zustand stores from the web app can be largely reused:

```typescript
// stores/editorStore.ts (iPad adaptation)
interface EditorStore {
  // Tab Management
  tabs: QueryTab[];
  activeTabId: string;

  // Query State
  activeQuery: string;
  isExecuting: boolean;

  // Results
  results: QueryResults | null;
  pinnedResultsTabId: string | null;

  // iPad-specific
  querySidebarVisible: boolean;      // Results interface sidebar
  resultsPreviewExpanded: boolean;   // Query interface preview

  // Actions
  setActiveTab: (id: string) => void;
  executeQuery: () => Promise<void>;
  toggleQuerySidebar: () => void;
  toggleResultsPreview: () => void;
}
```

```typescript
// stores/connectionStore.ts (iPad adaptation)
interface ConnectionStore {
  connections: Connection[];
  activeConnectionId: string | null;
  connectionStatus: Record<string, ConnectionStatus>;

  // Schema Cache
  schemas: Schema[];
  selectedSchemaId: string | null;

  // Actions
  connect: (id: string) => Promise<void>;
  disconnect: () => void;
  refreshSchema: () => Promise<void>;
}
```

### State Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         USER ACTIONS                             │
└─────────────────────────────────────────────────────────────────┘
          │                    │                    │
          ▼                    ▼                    ▼
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │   Select    │     │   Write     │     │   Execute   │
   │ Connection  │     │   Query     │     │   Query     │
   └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
          │                    │                    │
          ▼                    ▼                    ▼
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │ connection  │     │   editor    │     │   editor    │
   │   Store     │     │   Store     │     │   Store     │
   │             │     │ .activeQuery│     │ .results    │
   └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
          │                    │                    │
          ▼                    ▼                    ▼
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │   Schema    │     │   Query     │     │  Results    │
   │   Tree      │     │   Editor    │     │   Grid      │
   │  Component  │     │  Component  │     │  Component  │
   └─────────────┘     └─────────────┘     └─────────────┘
```

---

## iPad-Specific Design Considerations

### Touch Target Guidelines

| Element | Minimum Size | Recommended Size |
|---------|-------------|------------------|
| Buttons | 44 × 44 pt | 48 × 48 pt |
| List Items | 44 pt height | 56 pt height |
| Tab Bar Items | 49 pt height | Standard iOS |
| Touch Margins | 8 pt | 12 pt |

### Gestures

| Gesture | Action |
|---------|--------|
| **Swipe Left** (on query tab) | Close tab |
| **Swipe Right** (from screen edge) | Open query sidebar (Results interface) |
| **Pinch** | Zoom results grid |
| **Long Press** (on table name) | Insert table name into query |
| **Long Press** (on saved query) | Context menu (rename, delete, duplicate) |
| **Drag** (on saved query) | Reorder / move to folder |
| **Double Tap** (on cell) | Copy cell value |

### Keyboard Handling

```typescript
// Keyboard shortcuts for external keyboard
const keyboardShortcuts = {
  'Cmd+Enter': 'Execute query',
  'Cmd+S': 'Save query',
  'Cmd+Shift+F': 'Format SQL',
  'Cmd+N': 'New query tab',
  'Cmd+W': 'Close current tab',
  'Cmd+1-9': 'Switch to tab N',
  'Cmd+[': 'Previous tab',
  'Cmd+]': 'Next tab',
  'Escape': 'Close sidebar / Cancel',
};
```

### Multitasking Support

| Mode | Layout Adjustment |
|------|------------------|
| **Full Screen** | Standard two-interface design |
| **Split View (50/50)** | Collapse sidebar to icons only |
| **Split View (33/66)** | Single-panel mode, swipe to switch |
| **Slide Over** | Compact single-panel mode |

---

## Implementation Phases

### Phase 1: Foundation (2-3 weeks)

- [ ] Project setup with Expo + React Native
- [ ] Port Zustand stores from web codebase
- [ ] Implement PostgreSQL connection service
- [ ] Basic navigation structure (two tabs)
- [ ] Glass-morphism theme system

### Phase 2: Query Interface (3-4 weeks)

- [ ] Connection list component
- [ ] Schema tree browser
- [ ] Query editor with syntax highlighting
- [ ] Query tabs management
- [ ] Basic query execution
- [ ] Results preview component

### Phase 3: Results Interface (2-3 weeks)

- [ ] Full-screen results grid with virtualization
- [ ] Column resizing and reordering
- [ ] Cell selection and copy
- [ ] Export functionality (CSV, JSON)
- [ ] Sliding query sidebar

### Phase 4: Saved Queries (1-2 weeks)

- [ ] Saved queries panel
- [ ] Folder organization
- [ ] Query save/load functionality
- [ ] Local SQLite persistence

### Phase 5: Polish & Testing (2-3 weeks)

- [ ] iPad multitasking support
- [ ] External keyboard shortcuts
- [ ] Accessibility (VoiceOver)
- [ ] Performance optimization
- [ ] Beta testing and bug fixes

### Phase 6: App Store Preparation (1 week)

- [ ] App icons and screenshots
- [ ] App Store metadata
- [ ] Privacy policy and terms
- [ ] TestFlight distribution
- [ ] App Store submission

---

## Technical Specifications

### Minimum Requirements

| Requirement | Specification |
|-------------|---------------|
| **iOS Version** | iOS 15.0+ |
| **iPad Models** | iPad (8th gen+), iPad Air (4th+), iPad Pro (all) |
| **Storage** | ~100 MB app size |
| **Network** | Required for database connectivity |

### Dependencies

```json
{
  "dependencies": {
    "react": "^18.2.0",
    "react-native": "^0.73.0",
    "expo": "^50.0.0",
    "@react-navigation/native": "^6.1.0",
    "@react-navigation/bottom-tabs": "^6.5.0",
    "zustand": "^4.5.0",
    "@shopify/flash-list": "^1.6.0",
    "react-native-code-editor": "^1.3.0",
    "expo-sqlite": "^13.0.0",
    "react-native-gesture-handler": "^2.14.0",
    "react-native-reanimated": "^3.6.0"
  }
}
```

### Database Connectivity

For PostgreSQL connectivity on iOS, options include:

1. **Direct Connection** (react-native-postgres)
   - Pros: Real-time, full feature support
   - Cons: Requires network access, no offline

2. **Proxy Server** (API intermediary)
   - Pros: Enhanced security, logging
   - Cons: Additional infrastructure

3. **SSH Tunneling** (for secure connections)
   - Pros: Enterprise security requirements
   - Cons: Complex setup

**Recommendation**: Start with direct connection, add proxy option for enterprise deployments.

---

## Design System

### Color Palette (Dark Theme - Default)

```css
/* Backgrounds */
--bg-primary: rgba(0, 0, 0, 0.75);
--bg-surface: rgba(30, 30, 30, 0.85);
--bg-elevated: rgba(45, 45, 45, 0.9);

/* Text */
--text-primary: rgba(255, 255, 255, 1.0);
--text-secondary: rgba(255, 255, 255, 0.7);
--text-tertiary: rgba(255, 255, 255, 0.5);

/* Accents */
--accent-blue: #0A84FF;
--accent-green: #30D158;
--accent-red: #FF453A;
--accent-yellow: #FFD60A;

/* Syntax Highlighting */
--syntax-keyword: #FF79C6;
--syntax-string: #F1FA8C;
--syntax-number: #BD93F9;
--syntax-comment: #6272A4;
```

### Typography

```css
/* iOS System Fonts */
--font-primary: -apple-system, SF Pro Text;
--font-mono: SF Mono, Menlo, monospace;

/* Sizes */
--text-xs: 11px;
--text-sm: 13px;
--text-base: 15px;
--text-lg: 17px;
--text-xl: 20px;
--text-2xl: 24px;
```

---

## Success Metrics

| Metric | Target |
|--------|--------|
| App Launch Time | < 2 seconds |
| Query Execution Feedback | < 100ms to show loading |
| Results Grid Scroll | 60 FPS |
| Memory Usage | < 200 MB typical |
| Crash Rate | < 0.1% |
| App Store Rating | 4.5+ stars |

---

## Conclusion

This strategy provides a comprehensive roadmap for building an iPad version of Pharos that leverages the existing React/TypeScript codebase while optimizing for touch-based interaction and the iPad's unique capabilities. The two-interface approach (Query-focused and Results-focused) aligns with how database professionals work, allowing them to efficiently switch between query authoring and data analysis workflows.

The phased implementation approach allows for iterative development and early user feedback, while the technology choices (React Native + Expo) maximize code reuse from the existing desktop application.
