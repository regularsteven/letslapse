<?php
/**
 * LetsLapse theme bootstrap.
 *
 * @package LetsLapse
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

define( 'LETSLAPSE_VERSION', '0.3.0' );

require_once get_theme_file_path( 'inc/config.php' );
require_once get_theme_file_path( 'inc/blocks.php' );
require_once get_theme_file_path( 'inc/assets.php' );

/**
 * Theme supports.
 */
function letslapse_setup() {
	add_theme_support( 'wp-block-styles' );
	add_theme_support( 'responsive-embeds' );
	add_theme_support( 'editor-styles' );
	add_theme_support( 'post-thumbnails' );
	add_theme_support( 'html5', array( 'style', 'script' ) );

	add_editor_style( 'style.css' );

	load_theme_textdomain( 'letslapse', get_theme_file_path( 'languages' ) );
}
add_action( 'after_setup_theme', 'letslapse_setup' );
