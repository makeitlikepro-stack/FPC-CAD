// FPC Visual IDE - theme template (engine CSS + colour roles).
// Engine CSS: '.class' / '.class:hover|pressed|focus|disabled', #RRGGBB[AA], px.
// Only '//' line comments are supported. A rule overrides the engine's built-in
// class of the same name property by property.
// Colours are roles of the palette (assets/theme/dark.palette, user copy in
// <config>/fpc-visual-ide/theme.palette), written as the role name in double
// braces (= #RRGGBB) or role name + ':AA' in double braces (= that colour with
// alpha AA).  Never write double braces in a comment.  #00000000 = transparent.
// The IDE renders this file into <config>/fpc-visual-ide/ide-theme.css.

// ---- Theme Editor General dashboard cards
.ide-theme-home-card { background-color: {{popup}}; color: {{text-strong}}; border-color: {{border}}; border-width: 1px; border-radius: 10px; font-size: 16px; font-weight: 600; text-align: center; }
.ide-theme-home-card:hover { background-color: {{hover}}; border-color: {{accent}}; }
.ide-theme-home-card:pressed { background-color: {{pressed}}; border-color: {{accent}}; }

// ---- generic
.basic-label { color: {{text}}; }
.basic-panel { background-color: {{surface}}; border-width: 0px; border-radius: 0px; color: {{text}}; }

// ---- menu bar and drop-down menus: flat, no border, no rounding
.ui-menubar { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-menubar-item { background-color: #00000000; color: {{text}}; border-width: 0px; border-radius: 0px; font-size: 13px; font-weight: 400; }
.ui-menubar-item:hover { background-color: {{hover}}; }
.ui-menubar-item:pressed { background-color: {{pressed}}; }
.ui-menubar-item-focus { background-color: {{hover}}; color: {{text-strong}}; border-width: 0px; border-radius: 0px; glow-size: 0px; font-size: 13px; font-weight: 400; }
.ui-menubar-item-open { background-color: {{accent}}; color: {{text-strong}}; border-width: 0px; border-radius: 0px; glow-size: 0px; font-size: 13px; font-weight: 400; }
.ui-context-menu { background-color: {{popup}}; border-color: {{border}}; border-width: 1px; border-radius: 0px; shadow-color: {{shadow:80}}; shadow-offset-y: 2px; shadow-blur: 8px; }
.ui-list-item { background-color: #00000000; color: {{text}}; border-width: 0px; border-radius: 0px; font-size: 13px; }
.ui-list-item:hover { background-color: {{accent}}; }
.ui-list-item:pressed { background-color: {{accent-pressed}}; }
.ui-list-item-selected { background-color: {{accent}}; color: {{text-strong}}; border-width: 0px; border-radius: 0px; font-size: 13px; }
.submenu-chevron { background-color: {{text-muted}}; }
.ui-menu-separator { background-color: {{border}}; }
.ui-menu-shortcut { color: {{text-muted}}; font-size: 12px; }
.ide-menu-preview { background-color: {{popup}}; border-color: {{border}}; border-width: 1px; border-radius: 0px; shadow-color: {{shadow:80}}; shadow-offset-y: 2px; shadow-blur: 8px; }
.ide-menu-preview-row { background-color: #00000000; color: {{text}}; border-width: 0px; border-radius: 0px; font-size: 13px; padding-left: 12px; }
.ide-menu-preview-row:hover { background-color: {{hover}}; }
.ide-menu-preview-selected { background-color: {{accent}}; color: {{text-strong}}; border-width: 0px; border-radius: 0px; font-size: 13px; padding-left: 12px; }
.ide-menu-preview-line { background-color: {{border}}; }
.ui-popupmenu-host { background-color: {{popup}}; border-color: {{border}}; border-width: 1px; border-radius: 3px; color: {{text-muted}}; font-size: 11px; }

// ---- tool bar
.ui-toolbar { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-toolbar-button { background-color: #00000000; color: {{text}}; border-width: 0px; border-radius: 5px; }
.ui-toolbar-button:hover { background-color: {{hover}}; }
.ui-toolbar-button:pressed { background-color: {{pressed}}; }
.ui-toolbar-button-focus { background-color: {{hover}}; color: {{text-strong}}; border-width: 0px; border-radius: 5px; glow-size: 0px; font-weight: 400; }
.ui-toolbar-button-focus:focus { border-width: 0px; glow-size: 0px; }
.ui-toolbar-separator { background-color: {{border}}; }

// ---- docking
.ui-dock-host { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-dock-panel { background-color: {{chrome}}; border-color: {{border}}; border-width: 0px; border-top-left-radius: 0px; border-top-right-radius: 0px; border-bottom-right-radius: 0px; border-bottom-left-radius: 0px; }
.ui-dock-content { background-color: #00000000; border-width: 0px; border-radius: 0px; }
.ui-dock-title { background-color: {{chrome}}; color: {{text}}; border-color: {{border}}; border-width: 0px; border-top-left-radius: 0px; border-top-right-radius: 0px; border-bottom-right-radius: 0px; border-bottom-left-radius: 0px; font-size: 11px; }
.ui-dock-title:hover { background-color: {{popup}}; }
.ui-dock-title-active { background-color: {{chrome}}; color: {{text-strong}}; border-color: {{border}}; border-width: 0px; border-top-left-radius: 0px; border-top-right-radius: 0px; border-bottom-right-radius: 0px; border-bottom-left-radius: 0px; font-size: 11px; }
.ui-dock-title-active:hover { background-color: {{popup}}; }
.ui-dock-title-text { background-color: #00000000; color: {{text}}; font-size: 11px; font-weight: 700; text-transform: uppercase; }
.ui-dock-button { background-color: #00000000; color: {{text-muted}}; border-color: {{border}}; border-width: 0px; border-top-left-radius: 4px; border-top-right-radius: 4px; border-bottom-right-radius: 4px; border-bottom-left-radius: 4px; font-size: 12px; }
.ui-dock-button:hover { background-color: {{overlay:1A}}; }
.ui-dock-button:pressed { background-color: {{overlay:2E}}; }
.ui-dock-splitter { background-color: {{line}}; border-width: 0px; border-radius: 0px; }
.ui-dock-splitter-active { background-color: {{accent}}; border-width: 0px; border-radius: 0px; }
.ui-dock-splitter-grip { background-color: #00000000; border-width: 0px; border-radius: 0px; }
.ui-dock-tabbar { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-dock-tab { background-color: #00000000; color: {{text-muted}}; border-color: {{border}}; border-width: 0px; border-top-left-radius: 4px; border-top-right-radius: 4px; border-bottom-right-radius: 4px; border-bottom-left-radius: 4px; font-size: 12px; }
.ui-dock-tab:hover { background-color: {{hover}}; color: {{text-strong}}; }
.ui-dock-tab-active { background-color: {{accent}}; color: {{text-strong}}; border-color: {{border}}; border-width: 0px; border-top-left-radius: 4px; border-top-right-radius: 4px; border-bottom-right-radius: 4px; border-bottom-left-radius: 4px; font-size: 12px; font-weight: 700; }
.ui-dock-drop-hint { background-color: {{accent:33}}; border-color: {{accent}}; border-width: 2px; border-radius: 0px; }

// ---- editor tabs (attached style: the selected tab and its page are one surface)
.ui-tabs { background-color: {{tabbar}}; border-width: 0px; border-radius: 0px; }
.ui-tabs-bar-attached { background-color: {{tabbar}}; border-color: {{border}}; border-width: 0px; border-radius: 0px; }
.ui-tab-attached { background-color: #00000000; color: {{text-muted}}; border-color: {{border}}; border-width: 0px; border-radius: 6px; border-top-left-radius: 6px; border-top-right-radius: 6px; border-bottom-right-radius: 6px; border-bottom-left-radius: 6px; font-size: 13px; font-weight: 400; }
.ui-tab-attached:hover { background-color: {{hover}}; }
.ui-tab-attached:pressed { background-color: {{pressed}}; }
.ui-tab-attached-active-content { background-color: #00000000; color: {{text-strong}}; border-width: 0px; font-size: 13px; font-weight: 700; }
.ui-tab-attached-active-content-focus { background-color: #00000000; color: {{text-strong}}; border-width: 0px; font-size: 13px; font-weight: 700; }
.ui-tab-active-surface-top { background-color: {{editor}}; border-color: {{accent}}; border-width: 0px; border-top-left-radius: 8px; border-top-right-radius: 8px; border-bottom-right-radius: 0px; border-bottom-left-radius: 0px; }
.ui-tab-page-attached { background-color: {{editor}}; border-color: {{border}}; border-width: 0px; border-top-left-radius: 0px; border-top-right-radius: 0px; border-bottom-right-radius: 0px; border-bottom-left-radius: 0px; font-size: 13px; }
.ui-tab-separator { background-color: #00000000; }
.ui-tab-close { background-color: #00000000; color: {{text-muted}}; border-color: {{border}}; border-width: 0px; border-radius: 9px; font-size: 12px; }
.ui-tab-close:hover { background-color: {{overlay:1F}}; }
.ui-tab-close:pressed { background-color: {{overlay:33}}; }
.ui-tab-scroll { background-color: #00000000; color: {{text-muted}}; border-radius: 4px; }
.ui-tab-scroll:hover { background-color: {{hover}}; }

// ---- explorer tree
.ui-tree { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-tree-content { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-tree-row { background-color: #00000000; color: {{text}}; border-width: 0px; border-radius: 0px; font-size: 13px; font-weight: 400; }
.ui-tree-row:hover { background-color: {{hover}}; }
.ui-tree-row:pressed { background-color: {{pressed}}; }
.ui-tree-row-focused { background-color: #00000000; color: {{text}}; border-color: {{accent}}; border-width: 1px; border-radius: 0px; font-size: 13px; font-weight: 400; }
.ui-tree-row-selected { background-color: {{selection}}; color: {{text-strong}}; border-width: 0px; border-radius: 0px; font-size: 13px; font-weight: 400; }
.ui-tree-row-selected:hover { background-color: {{selection}}; }
.ui-tree-row-selected-focus { background-color: {{accent}}; color: {{text-strong}}; border-width: 0px; border-radius: 0px; font-size: 13px; font-weight: 400; }
.ui-tree-expander { background-color: #00000000; color: {{text-muted}}; border-width: 0px; border-radius: 4px; }
.ui-tree-expander:hover { background-color: {{overlay:14}}; }

// ---- scroll bars (thin, square, translucent like the code editor)
.ui-scroll { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-scroll-track { background-color: #00000000; border-width: 0px; border-radius: 0px; }
.ui-scroll-thumb { background-color: {{overlay:2E}}; border-width: 0px; border-radius: 0px; }
.ui-scroll-thumb:hover { background-color: {{overlay:4D}}; }
.ui-scroll-thumb:pressed { background-color: {{overlay:66}}; }

// ---- status bar
.ui-statusbar { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-statusbar-text { background-color: #00000000; color: {{text}}; font-size: 12px; }
.ui-statusbar-separator { background-color: {{line}}; }

// ---- tooltips and dialogs
.ui-tooltip { background-color: {{popup}}; border-color: {{popup-border}}; border-width: 1px; border-radius: 3px; }
.ui-tooltip-text { color: {{text}}; font-size: 12px; }
.ui-dialog { background-color: {{popup}}; border-color: {{popup-border}}; border-width: 1px; border-radius: 8px; }
.ui-dialog-title { background-color: {{chrome}}; border-top-left-radius: 7px; border-top-right-radius: 7px; }
.ui-dialog-buttons { background-color: {{chrome}}; border-bottom-right-radius: 7px; border-bottom-left-radius: 7px; }
.ui-dialog-button { background-color: {{surface}}; color: {{text}}; border-color: {{border}}; border-width: 1px; border-radius: 4px; }
.ui-dialog-button:hover { background-color: {{border}}; border-color: {{accent}}; }
.ui-dialog-button-primary { background-color: {{accent}}; color: {{text-strong}}; border-color: {{accent}}; border-width: 1px; border-radius: 4px; }
.ui-dialog-button-primary:hover { background-color: {{accent-hover}}; border-color: {{accent-hover}}; }

// ---- form designer: canvas around the form, selection outline and handles
// Designer lines are dashes: padding = dash length, gap = space between
// dashes (0px = solid).  min-width of a handle = its size; its
// border-radius gives the shape (half the size = round).
.ide-design-scroll { background-color: {{canvas}}; border-width: 0px; border-radius: 0px; }
.ide-design-surface { background-color: {{canvas}}; border-width: 0px; border-radius: 0px; }
.ide-design-outline { background-color: {{focus}}; padding: 4px; gap: 3px; border-width: 0px; border-radius: 0px; shadow-blur: 0px; glow-size: 0px; }
.ide-design-guide { background-color: {{guide}}; padding: 4px; gap: 3px; border-width: 0px; border-radius: 0px; shadow-blur: 0px; glow-size: 0px; }
.ide-design-handle { background-color: {{text-strong}}; border-color: {{focus}}; border-width: 1px; border-radius: 0px; min-width: 7px; shadow-blur: 0px; glow-size: 0px; }
.ide-design-handle:hover { background-color: {{focus}}; }
.ide-design-rotate { background-color: {{text-strong}}; border-color: {{focus}}; border-width: 1px; border-radius: 5px; min-width: 10px; shadow-blur: 0px; glow-size: 0px; }
.ide-design-rotate:hover { background-color: {{focus}}; }
.ide-design-radius { background-color: {{guide}}; border-color: {{text-strong}}; border-width: 1px; border-radius: 5px; min-width: 9px; shadow-blur: 0px; glow-size: 0px; }
.ide-design-radius:hover { background-color: {{focus}}; }
.ide-style-bar { background-color: {{chrome}}; border-color: {{border}}; border-width: 1px; border-radius: 4px; shadow-color: #00000055; shadow-blur: 6px; }
.ide-style-grip { background-color: {{text-muted}}; border-width: 0px; border-radius: 2px; min-width: 6px; shadow-blur: 0px; glow-size: 0px; }
.ide-style-grip:hover { background-color: {{focus}}; }
.ide-style-separator { background-color: {{text-muted}}; border-width: 0px; border-radius: 0px; }
.ide-palette-tab { background-color: {{chrome}}; color: {{text}}; border-color: {{border}}; border-width: 1px; border-radius: 4px; font-size: 11px; }
.ide-palette-tab:hover { background-color: {{focus}}; }
.ide-palette-tab-active { background-color: {{focus}}; color: {{text-strong}}; border-color: {{focus}}; border-width: 1px; border-radius: 4px; font-size: 11px; }

// ---- toolbox: flat rows, hover box, armed tool highlighted like a selection
.ide-toolbox { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ide-toolbox-search { background-color: {{surface}}; color: {{text-strong}}; border-color: {{border}}; border-width: 1px; border-radius: 5px; font-size: 12px; text-align: left; }
.ide-toolbox-search:focus { border-color: {{focus}}; glow-size: 0px; }
.ide-toolbox-category { background-color: {{line}}; color: {{text-strong}}; border-width: 0px; border-radius: 4px; font-size: 12px; font-weight: 600; text-align: left; }
.ide-toolbox-count { background-color: #00000000; color: {{text-muted}}; border-width: 0px; font-size: 11px; text-align: right; }
.ide-toolbox-category:hover { background-color: {{hover}}; }
.ide-toolbox-empty { background-color: #00000000; color: {{text-muted}}; border-width: 0px; font-size: 12px; }
.ide-toolbox-item { background-color: #00000000; border-width: 0px; border-radius: 4px; shadow-blur: 0px; glow-size: 0px; }
.ide-toolbox-item:hover { background-color: {{hover}}; }
.ide-toolbox-item:pressed { background-color: {{pressed}}; }
.ide-toolbox-item-armed { background-color: {{accent}}; border-color: {{focus}}; border-width: 1px; border-radius: 4px; shadow-blur: 0px; glow-size: 0px; }
.ide-toolbox-item-armed:hover { background-color: {{accent}}; }
.ide-toolbox-caption { background-color: #00000000; color: {{text}}; border-width: 0px; font-size: 13px; font-weight: 400; }
.ui-dock-tab-active:hover { background-color: {{accent}}; }

// ---- Object Inspector (root panel + engine property grid)
.ide-inspector-search { background-color: {{surface}}; color: {{text-strong}}; border-color: {{border}}; border-width: 1px; border-radius: 5px; font-size: 12px; text-align: left; }
.ide-inspector-search:focus { border-color: {{focus}}; glow-size: 0px; }
.ide-inspector-tab { background-color: #00000000; color: {{text-muted}}; border-width: 0px; border-radius: 3px; font-size: 11px; text-align: center; }
.ide-inspector-tab:hover { background-color: {{hover}}; color: {{text-strong}}; }
.ide-inspector-tab-selected { background-color: {{accent:2B}}; color: {{text-strong}}; border-color: {{accent}}; border-width: 1px; border-radius: 3px; font-size: 11px; font-weight: 700; text-align: center; }
.ide-inspector-tab-selected:hover { background-color: {{accent:40}}; }
.ide-inspector { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; color: {{text}}; }
.basic-button { background-color: {{surface}}; color: {{text-strong}}; border-color: {{button-border}}; border-width: 1px; border-radius: 4px; glow-size: 0px; shadow-blur: 0px; font-size: 13px; font-weight: 600; }
.basic-button:hover { background-color: {{line}}; border-color: {{text-muted}}; }
.basic-button:pressed { background-color: {{accent}}; border-color: {{accent}}; }
.ui-propgrid { background-color: {{chrome}}; border-color: {{line}}; border-width: 1px; border-radius: 0px; }
.ui-propgrid:focus { border-color: {{accent}}; }
.ui-propgrid-row { background-color: {{chrome}}; border-width: 0px; border-radius: 0px; }
.ui-propgrid-row-alt { background-color: {{row-alt}}; border-width: 0px; border-radius: 0px; }
.ui-propgrid-row-selected { background-color: {{accent}}; border-width: 0px; border-radius: 0px; }
.ui-propgrid-category { background-color: {{category}}; color: {{text-strong}}; border-width: 0px; border-radius: 0px; font-size: 12px; font-weight: 700; text-align: left; vertical-align: center; }
.ui-propgrid-category-selected { background-color: {{accent}}; color: {{text-strong}}; border-width: 0px; border-radius: 0px; font-size: 12px; font-weight: 700; text-align: left; vertical-align: center; }
.ui-propgrid-glyph { background-color: #00000000; color: {{text-muted}}; font-size: 11px; text-align: center; vertical-align: center; }
.ui-propgrid-name { background-color: #00000000; color: {{text}}; font-size: 12px; text-align: left; vertical-align: center; }
.ui-propgrid-value { background-color: #00000000; color: {{text-strong}}; font-size: 12px; text-align: left; vertical-align: center; }
.ui-propgrid-value-readonly { background-color: #00000000; color: {{text-disabled}}; font-size: 12px; text-align: left; vertical-align: center; }
.ui-propgrid-divider { background-color: {{line}}; border-width: 0px; border-radius: 0px; }
.ui-propgrid-editor { background-color: {{popup}}; color: {{text-strong}}; border-color: {{accent}}; border-width: 1px; border-radius: 3px; font-size: 12px; text-align: left; vertical-align: center; }
.ui-propgrid-editor:focus { border-color: {{focus}}; glow-size: 0px; }

