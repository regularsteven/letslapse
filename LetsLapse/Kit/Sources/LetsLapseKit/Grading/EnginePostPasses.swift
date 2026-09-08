import CoreImage
import Foundation

/// The controls that render AFTER the tone engine, over its display-referred
/// output, rather than inside the Metal kernel.
///
/// Today that is Dehaze and the HSL panel. The dark-channel prior estimates the haze's colour
/// from the brightest of the picture's darkest patches, which needs the whole
/// frame in one place; and it acts on the rendered picture, the way it does
/// in Lightroom's own pipeline. So it runs here, once, on the image the
/// engine hands back — and every path that renders a recipe (the editor
/// preview, a JPEG export, a stills blend, the CLI) calls this same function
/// after the engine, so the control means one thing everywhere.
///
/// A neutral recipe costs nothing: `apply` hands back the input.
public enum EnginePostPasses {

    /// True when `recipe` asks for anything rendered here — the cheap check
    /// a caller makes before bothering to wrap a texture as a `CIImage`.
    public static func isNeeded(_ recipe: GradeRecipe) -> Bool {
        abs(recipe.dehaze) > 1e-6 || recipe.hasHSL
    }

    /// `image` with the recipe's post-engine controls applied.
    public static func apply(
        _ image: CIImage, recipe: GradeRecipe, context: CIContext? = nil
    ) -> CIImage {
        guard isNeeded(recipe) else { return image }
        var out = image
        if abs(recipe.dehaze) > 1e-6,
           let hazed = Dehaze.apply(out, amount: Double(recipe.dehaze), context: context) {
            out = hazed
        }
        // HSL after dehaze: the panel judges colours as the picture shows
        // them, and dehaze has just changed what it shows.
        if let hsl = recipe.hsl, !hsl.isNeutral, let shifted = HSLAdjustments.apply(hsl, to: out) {
            out = shifted
        }
        return out
    }
}
