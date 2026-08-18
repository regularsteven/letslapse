<?php
/**
 * Title: Loading hero
 * Slug: letslapse/hero-rig
 * Categories: letslapse, featured
 * Block Types: core/post-content
 * Description: The rig assembles itself on load — legs, body, board, lens — and hands over to a headline, a line of copy and a call to action.
 *
 * The same animation the app plays at launch, so a first visit to the site and
 * a first launch of the app open the same way.
 *
 * @package LetsLapse
 */

?>
<!-- wp:letslapse/rig-hero {"markSize":240} -->
<!-- wp:heading {"level":1,"className":"is-style-ll-display"} -->
<h1 class="wp-block-heading is-style-ll-display">Every build, on tape.</h1>
<!-- /wp:heading -->

<!-- wp:paragraph {"className":"is-style-ll-standfirst"} -->
<p class="is-style-ll-standfirst">Set the rig, walk away, get the film.</p>
<!-- /wp:paragraph -->

<!-- wp:buttons {"layout":{"type":"flex","justifyContent":"center"}} -->
<div class="wp-block-buttons"><!-- wp:button -->
<div class="wp-block-button"><a class="wp-block-button__link wp-element-button" href="#get">Get the app</a></div>
<!-- /wp:button --></div>
<!-- /wp:buttons -->
<!-- /wp:letslapse/rig-hero -->
