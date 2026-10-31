// FPC-CAD additions over the FPC Visual IDE template (same role syntax).
// ---- buttons, labels, edits
.basic-button { background-color: {{surface}}; color: {{text}}; border-color: {{button-border}}; border-width: 1px; border-radius: 5px; font-size: 12px; }
.basic-button:hover { background-color: {{hover}}; border-color: {{accent}}; }
.basic-button:pressed { background-color: {{pressed}}; }
.basic-button:disabled { background-color: {{chrome}}; color: {{text-disabled}}; border-color: {{line}}; }
.basic-label { color: {{text}}; font-size: 12px; }
.ui-edit { background-color: {{surface}}; color: {{text}}; border-color: {{border}}; border-width: 1px; border-radius: 4px; font-size: 13px; }
.ui-edit:focus { border-color: {{focus}}; }
.ui-edit:disabled { background-color: {{chrome}}; color: {{text-disabled}}; }
// ---- slider
.basic-slider-track { background-color: {{line}}; }
.basic-slider-fill { background-color: {{focus}}; }
.basic-slider-knob { background-color: {{surface}}; border-color: {{focus}}; border-width: 2px; }
// ---- list and group boxes
.ui-listbox { background-color: {{surface}}; color: {{text}}; border-color: {{border}}; border-width: 1px; border-radius: 4px; }
.ui-group { background-color: {{surface}}; color: {{text}}; border-color: {{line}}; border-width: 1px; border-radius: 6px; }
.ui-group-caption { color: {{text-strong}}; font-size: 12px; font-weight: 600; }
.ui-group-content { background-color: {{surface}}; border-width: 0px; }
// ---- ribbon and side tabs (pill style)
.ui-tabs { background-color: {{surface}}; border-color: {{line}}; border-width: 0px; border-radius: 0px; }
.ui-tabs-bar { background-color: {{surface}}; border-width: 0px; border-radius: 0px; }
.ui-tab { background-color: #00000000; color: {{text-muted}}; border-width: 0px; border-radius: 4px; font-size: 12px; }
.ui-tab:hover { background-color: {{hover}}; }
.ui-tab-active { background-color: {{selection}}; color: {{focus}}; border-width: 0px; border-radius: 4px; font-size: 12px; font-weight: 600; }
.ui-tab-active-focus { background-color: {{selection}}; color: {{focus}}; border-width: 0px; border-radius: 4px; font-size: 12px; font-weight: 600; }
.ui-tab-page { background-color: {{surface}}; border-color: {{line}}; border-width: 0px; border-radius: 0px; }
// ---- form background
.ui-form { background-color: {{chrome}}; color: {{text}}; }
