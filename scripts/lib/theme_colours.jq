# Binds a PBIR visual.json to the 'Theme Colours' measure table so the visual
# follows the light/dark Display Mode toggle. Used by apply_theme_colours.sh.
#
# Arguments (passed with --argjson):
#   $colours        {"Colour Text": {"light": "#2A2A2A", "dark": "#F7F7F7"}, ...}
#                   parsed from the template's 'Theme Colours' table.
#   $keep_literals  true to leave hard-coded hex colours untouched.
#
# Only properties that are unset (or set to a literal hex colour, unless
# $keep_literals) are written. Anything already bound to a measure, a rule or
# a gradient is treated as deliberate and left alone.

def tc_measure($name):
  {Measure: {Expression: {SourceRef: {Entity: "Theme Colours"}}, Property: $name}};

# Colour bound directly to a Theme Colours measure (field-value formatting).
def by_measure($name): {solid: {color: {expr: tc_measure($name)}}};

# Colour picked by a rule on [Display Mode Index]. Needed where Power BI does
# not accept a colour measure, e.g. the new card visual's fonts and fills.
def by_rule($name):
  if $colours[$name] == null then error("Theme Colours has no measure named '\($name)'") else . end
  | def case($index; $hex):
      {Condition: {Comparison: {ComparisonKind: 0,
                                Left: tc_measure("Display Mode Index"),
                                Right: {Literal: {Value: "\($index)L"}}}},
       Value: {Literal: {Value: "'\($hex)'"}}};
    {solid: {color: {expr: {Conditional: {Cases: [
      case(1; $colours[$name].dark),
      case(0; $colours[$name].light)
    ]}}}}};

def replaceable:
  . == null or ((.solid.color.expr | keys) == ["Literal"] and ($keep_literals | not));

# Set <group>.<object>[selector].properties.<prop> = $value when replaceable.
# $selector is null for container objects and axis objects (no selector key).
def bind($group; $object; $selector; $prop; $value):
  (.visual[$group][$object] // []) as $entries
  | ($entries | map((.selector // null) == $selector) | index(true)) as $i
  | if $i == null then
      .visual[$group][$object] = $entries + [
        {properties: {($prop): $value}} + (if $selector == null then {} else {selector: $selector} end)
      ]
    elif ($entries[$i].properties[$prop] | replaceable) then
      .visual[$group][$object][$i].properties[$prop] = $value
    else . end;

def container($object; $prop; $value): bind("visualContainerObjects"; $object; null; $prop; $value);
def object($object; $prop; $value): bind("objects"; $object; null; $prop; $value);

def all_series: {data: [{dataViewWildcard: {matchingOption: 1}}]};
def default_sel: {id: "default"};

def chart_types: [
  "barChart", "clusteredBarChart", "stackedBarChart", "hundredPercentStackedBarChart",
  "columnChart", "clusteredColumnChart", "stackedColumnChart", "hundredPercentStackedColumnChart",
  "lineChart", "areaChart", "stackedAreaChart", "hundredPercentStackedAreaChart",
  "lineClusteredColumnComboChart", "lineStackedColumnComboChart", "ribbonChart",
  "waterfallChart", "scatterChart"
];

# Decorative / free-form visuals keep whatever the author chose.
def skipped_types: ["shape", "basicShape", "image", "textbox", "actionButton", "pageNavigator", "bookmarkNavigator"];

def projections($role): [.visual.query.queryState[$role].projections[]?];

# The Mode toggle (anything slicing on 'Display Mode') is styled by design.
def is_mode_toggle: [.visual.query.queryState[]?.projections[]?.field.Column.Expression.SourceRef.Entity] | index("Display Mode");

if .visual == null or (.visual.visualType as $t | skipped_types | index($t)) or is_mode_toggle then .
else
  .visual.visualType as $type

  # Every data visual: container background, border and title.
  | container("background"; "color"; by_measure("Colour Surface"))
  | container("border"; "color"; by_measure("Colour Border"))
  | container("title"; "fontColor"; by_measure("Colour Text"))

  | if (chart_types | index($type)) then
      object("categoryAxis"; "labelColor"; by_measure("Colour Muted Text"))
      | object("valueAxis"; "labelColor"; by_measure("Colour Muted Text"))
      | bind("objects"; "labels"; all_series; "color"; by_measure("Colour Text"))
      # A single colour for every data point only makes sense for one series.
      | if (projections("Series") | length) == 0 and (projections("Y") | length) <= 1
        then bind("objects"; "dataPoint"; all_series; "fill"; by_measure("Colour Brand"))
        else . end

    elif $type == "cardVisual" then
      bind("objects"; "value"; default_sel; "fontColor"; by_rule("Colour Text"))
      | bind("objects"; "label"; default_sel; "fontColor"; by_rule("Colour Muted Text"))
      | bind("objects"; "fillCustom"; default_sel; "fillColor"; by_rule("Colour Surface"))
      | bind("objects"; "accentBar"; default_sel; "color"; by_rule("Colour Brand"))

    elif $type == "card" then
      object("labels"; "color"; by_measure("Colour Text"))
      | object("categoryLabels"; "color"; by_measure("Colour Muted Text"))

    elif $type == "pivotTable" or $type == "tableEx" then
      # Cell colours are set per value field, as Power BI does.
      reduce (projections("Values")[].queryRef) as $ref (.;
        {data: [{dataViewWildcard: {matchingOption: 0}}], metadata: $ref} as $sel
        | bind("objects"; "values"; $sel; "backColor"; by_measure("Colour Surface"))
        | bind("objects"; "values"; $sel; "fontColor"; by_measure("Colour Text")))

    else . end
end
