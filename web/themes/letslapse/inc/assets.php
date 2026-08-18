<?php
/**
 * Theme-level asset loading. Block assets load themselves via block.json.
 *
 * @package LetsLapse
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Front-end styles.
 */
function letslapse_enqueue_styles() {
	wp_enqueue_style(
		'letslapse',
		get_stylesheet_uri(),
		array(),
		LETSLAPSE_VERSION
	);
}
add_action( 'wp_enqueue_scripts', 'letslapse_enqueue_styles' );

/**
 * Favicon fallback.
 *
 * A site icon set in Settings > General always wins. This only covers the case
 * where nobody has set one, so a fresh install still shows the mark in the tab
 * rather than the WordPress default.
 */
function letslapse_favicon_fallback() {
	if ( function_exists( 'has_site_icon' ) && has_site_icon() ) {
		return;
	}

	printf(
		'<link rel="icon" href="%s" type="image/svg+xml" sizes="any">' . "\n",
		esc_url( get_theme_file_uri( 'assets/img/letslapse-icon-dark.svg' ) )
	);
}
add_action( 'wp_head', 'letslapse_favicon_fallback' );
