"""
Return the y value needed for the element to be vertically centered in the
middle of the xheight.
"""
function y_for_centered(font_family, elem)
    h = inkheight(elem)
    return h/2 + xheight(font_family)/2
end

"""
    tex_layout(mathexpr::TeXExpr, font_family)

Recursively determine the layout of the math expression represented the given
TeXExpr for the given font set.

Return a set of nested objects, positioned and scaled relative to their parent.
"""
tex_layout(expr, font_family::FontFamily) = tex_layout(expr, LayoutState(font_family))

function tex_layout(expr, state)
    font_family = state.font_family
    head = expr.head
    args = [expr.args...]
    shrink = 0.6

    try
        if head in [:char, :delimiter, :digit, :punctuation, :symbol]
            char = args[1]
            texchar = TeXChar(char, state, head)
            return texchar
        elseif head == :combining_accent
            accent, core = tex_layout.(args, state)

            y = topinkbound(core) - xheight(font_family)

            if core.slanted
                α = slant_angle(font_family)
                x = (y + bottominkbound(accent)) * tan(α) / 2
            else
                x = 0.0
            end

            return Group(
                [core, accent],
                Point2f[
                    (0, 0),
                    (x + hmid(core) - hmid(accent), 0)
                ],
                [1, 1]
            )
        elseif head == :decorated
            core, sub, super = tex_layout.(args, state)

            # Should be a bit smarter for slanted font
            return Group(
                [core, sub, super],
                Point2f[
                    (0, 0),
                    (rightinkbound(core) + 0.1, -0.2),
                    (rightinkbound(core) + 0.1, 0.9 * xheight(core))],
                [1, shrink, shrink]
            )
        elseif head == :delimited
            elements = tex_layout.(args, state)
            left, content, right = elements

            height = inkheight(content)
            left_scale = max(1, height / inkheight(left))
            right_scale = max(1, height / inkheight(right))
            scales = [left_scale, 1, right_scale]
                
            dxs = hadvance.(elements) .* scales
            xs = [0, cumsum(dxs[1:end-1])...]

            # TODO Height calculation for the parenthesis looks wrong
            # TODO Check what the algorithm should be there
            # Center the delimiters in the middle of the bot and top baselines ?
            return Group(elements, 
                Point2f[
                    (xs[1], -bottominkbound(left) + bottominkbound(content)),
                    (xs[2], 0),
                    (xs[3], -bottominkbound(right) + bottominkbound(content))
                ],
                scales
            )
        elseif head == :font
            modifier, content = args
            return tex_layout(content, add_font_modifier(state, modifier))
        elseif head == :frac
            numerator = tex_layout(args[1], state)
            denominator = tex_layout(args[2], state)

            # extend fraction line by half an xheight
            xh = xheight(font_family)
            w = max(inkwidth(numerator), inkwidth(denominator)) + xh/2

            # fixed width fraction line
            lw = thickness(font_family)

            line = HLine(w, lw)
            y0 = xh/2 - lw/2

            # horizontal center align for numerator and denominator
            x1 = (w-inkwidth(numerator))/2
            x2 = (w-inkwidth(denominator))/2

            ytop    = y0 + xh/2 - bottominkbound(numerator)
            ybottom = y0 - xh/2 - topinkbound(denominator)

            return Group(
                [line, numerator, denominator],
                Point2f[(0, y0), (x1, ytop), (x2, ybottom)]
            )
        elseif head == :function
            name = args[1]
            elements = TeXChar.(collect(name), state, Ref(:function))
            return horizontal_layout(elements)
        elseif head == :group || head == :expr
            elements = tex_layout.(args, state)
            return horizontal_layout(elements)
        elseif head == :integral
            pad = 0.1
            int, sub, super = tex_layout.(args, state)

            return Group(
                [int, sub, super],
                Point2f[
                    (0, 0),
                    (
                        0.15 - inkwidth(sub)*shrink/2,
                        bottominkbound(int) - topinkbound(sub)*shrink - pad
                    ),
                    (
                        0.85 - inkwidth(super)*shrink/2,
                        topinkbound(int) + pad
                    )
                ],
                [1, shrink, shrink]
            )
        elseif head == :space
            return Space(args[1])
        elseif head == :spaced
            sym = tex_layout(args[1], state)
            return horizontal_layout([Space(0.2), sym, Space(0.2)])
        elseif head == :sqrt
            content = tex_layout(args[1], state)
            h = inkheight(content)
            sqrt = nothing

            for name in ["radical.v1", "radical.v2", "radical.v3", "radical.v4"]
                sqrt = TeXChar(name, state, :symbol ; represented = '√')
                if inkheight(sqrt) >= 1.05h
                    pad = (inkheight(sqrt) - 1.05h) / 2
                    break
                end
            end

            h = inkheight(sqrt)

            lw = thickness(font_family)
            y0 = bottominkbound(content) - bottominkbound(sqrt) - pad
            y = y0 + topinkbound(sqrt) - lw

            hline = HLine(inkwidth(content) + pad, lw)

            return Group(
                [sqrt, hline, content, Space(1.2)],
                Point2f[
                    (0, y0),
                    (rightinkbound(sqrt) - lw/2, y + lw/2),
                    (rightinkbound(sqrt), 0),
                    (rightinkbound(content), 0)
                ]
            )

        elseif head == :underover
            core, sub, super = tex_layout.(args, state)

            mid = hmid(core)
            dxsub = mid - hmid(sub) * shrink
            dxsuper = mid - hmid(super) * shrink

            under_offset = bottominkbound(core) - 0.1 - ascender(sub) * shrink
            over_offset = topinkbound(core) - descender(super)

            # The leftmost element must have x = 0
            x0 = -min(0, dxsub, dxsuper)
            y0 = 0.0

            return Group(
                [core, sub, super],
                Point2f[
                    (x0, y0),
                    (x0 + dxsub, y0 + under_offset),
                    (x0 + dxsuper, y0 + over_offset)
                ],
                [1, shrink, shrink]
            )
        end
    catch
        # TODO Better error
        rethrow()
        @error "Error while layouting expr"
    end

    @error "Unsupported head $(head) in expr:\n$expr"
end

tex_layout(::Nothing, state) = Space(0)

"""
    horizontal_layout(elements)

Layout the elements horizontally, like normal text.
"""
function horizontal_layout(elements)
    dxs = hadvance.(elements)
    xs = [0, cumsum(dxs[1:end-1])...]

    return Group(elements, Point2f.(xs, 0))
end

function layout_text(string, font_family)
    isempty(string) && return Space(0)

    elements = TeXChar.(collect(string), LayoutState(font_family), Ref(:text))
    return horizontal_layout(elements)
end

"""
    unravel(element::TeXElement, pos, scale)

Flatten the layouted TeXElement and produce a single list of base element with
their associated absolute position and scale.
"""
function unravel(group::Group, parent_pos=Point2f(0), parent_scale=1.0f0)
    scales = group.scales .* parent_scale
    positions = [parent_pos .+ pos for pos in parent_scale .* group.positions]
    elements = []

    for (elem, pos, scale) in zip(group.elements, positions, scales)
        push!(elements, unravel(elem, pos, scale)...)
    end

    return elements
end

unravel(::Space, pos, scale) = []
unravel(element, pos, scale) = [(element, pos, scale)]

"""
    generate_tex_elements(str)

Create a list of tuple `(texelement, position, scale)` from a string
of LaTeX math mode code. The elements' positions and scales are such as to
approximatively reproduce the LaTeX output.

The elments are of one of the following types

    - `TeXChar` a (unicode) character with a specific font.
    - `HLine` a horizontal line.
    - `VLine` a vertical line.
"""
function generate_tex_elements(str, font_family=FontFamily())
    expr = texparse(str)
    layout = tex_layout(expr, font_family)
    return unravel(layout)
end

# Still hacky as hell
function generate_tex_elements(str::LaTeXString, font_family=FontFamily())
    parts = String.(split(str, raw"$"))
    groups = Vector{TeXElement}(undef, length(parts))
    texts = parts[1:2:end]
    maths = parts[2:2:end]

    groups[1:2:end] = layout_text.(texts, Ref(font_family))
    groups[2:2:end] = tex_layout.(texparse.(maths), Ref(font_family))

    return unravel(horizontal_layout(groups))
end