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
