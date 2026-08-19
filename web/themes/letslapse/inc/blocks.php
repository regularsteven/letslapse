<?php
/**
 * Block + shortcode registration.
 *
 * Every block is one self-contained unit: everything it needs lives in its own
 * directory under inc/blocks/. Nothing outside that directory renders it, so
 * any of them can be reworked without touching the header, the navigation or
 * any template.
 *
 * @package LetsLapse
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

require_once get_theme_file_path( 'inc/blocks/rig-hero/rig.php' );

/**
 * Register theme blocks.
 */
function letslapse_register_blocks() {
	register_block_type( get_theme_file_path( 'inc/blocks/hero-machine' ) );
	register_block_type( get_theme_file_path( 'inc/blocks/rig-hero' ) );
	register_block_type( get_theme_file_path( 'inc/blocks/brand-mark' ) );
}
add_action( 'init', 'letslapse_register_blocks' );

/**
 * Enqueue a block's registered front-end assets outside the block pipeline.
 *
 * Needed for the shortcode path, where nothing else pulls the view script in.
 *
 * @param string $block_name Registered block name.
 */
function letslapse_enqueue_block_assets( $block_name ) {
	$registry = WP_Block_Type_Registry::get_instance();
	$type     = $registry->get_registered( $block_name );

	if ( ! $type ) {
		return;
	}

	foreach ( (array) $type->style_handles as $handle ) {
		wp_enqueue_style( $handle );
	}

	foreach ( (array) $type->view_script_handles as $handle ) {
		wp_enqueue_script( $handle );
	}
}

/**
 * [letslapse_hero] — the same hero for classic editors and page builders.
 *
 * Accepts snake_case versions of every block attribute, e.g.
 * [letslapse_hero blend_ratio="20" output_count="6" show_timeline="false"]
 *
 * @param array|string $atts Shortcode attributes.
 * @return string
 */
function letslapse_hero_shortcode( $atts ) {
	$atts = shortcode_atts(
		array(
			'show_timeline'        => null,
			'show_playing_count'   => null,
			'source_label'         => null,
			'output_label'         => null,
			'timeline_label'       => null,
			'replay_label'         => null,
			'stacking_label'       => null,
			'playing_label'        => null,
			'resetting_label'      => null,
			'reduced_motion_label' => null,
			'blend_ratio'          => null,
			'output_count'         => null,
			'frame_count'          => null,
			'atlas_cols'           => null,
			'atlas_frame_size'     => null,
			'source_fps'           => null,
			'start_rate'           => null,
			'accel'                => null,
			'max_rate'             => null,
			'play_fps'             => null,
			'atlas_url'            => null,
			'atlas_id'             => null,
			'align'                => null,
			'anchor'               => null,
		),
		$atts,
		'letslapse_hero'
	);

	$attributes = array();

	foreach ( $atts as $key => $value ) {
		if ( null === $value ) {
			continue;
		}

		// blend_ratio -> blendRatio.
		$camel = lcfirst( str_replace( ' ', '', ucwords( str_replace( '_', ' ', $key ) ) ) );

		if ( 'showTimeline' === $camel || 'showPlayingCount' === $camel ) {
			$value = filter_var( $value, FILTER_VALIDATE_BOOLEAN );
		}

		$attributes[ $camel ] = $value;
	}

	letslapse_enqueue_block_assets( 'letslapse/hero-machine' );

	return render_block(
		array(
			'blockName'    => 'letslapse/hero-machine',
			'attrs'        => $attributes,
			'innerBlocks'  => array(),
			'innerHTML'    => '',
			'innerContent' => array(),
		)
	);
}
add_shortcode( 'letslapse_hero', 'letslapse_hero_shortcode' );

/**
 * Hand one block's editor script the same data the server renders from.
 *
 * @param string $block_name Registered block name.
 * @param string $global     Window property the editor script reads.
 * @param array  $data       Payload.
 */
function letslapse_inline_editor_data( $block_name, $global, $data ) {
	$type = WP_Block_Type_Registry::get_instance()->get_registered( $block_name );

	if ( ! $type ) {
		return;
	}

	$json = wp_json_encode( $data );

	foreach ( (array) $type->editor_script_handles as $handle ) {
		wp_add_inline_script( $handle, 'window.' . $global . ' = ' . $json . ';', 'before' );
	}
}

/**
 * Hand the editor the same schema, copy and artwork the server renders from,
 * so the editor preview cannot drift from the front end.
 */
function letslapse_block_editor_data() {
	letslapse_inline_editor_data(
		'letslapse/hero-machine',
		'letsLapseHero',
		array(
			'schema'        => letslapse_hero_schema(),
			'labelDefaults' => letslapse_hero_label_defaults(),
			'defaultAtlas'  => letslapse_hero_atlas_url( array() ),
		)
	);

	letslapse_inline_editor_data(
		'letslapse/rig-hero',
		'letsLapseRig',
		array(
			'schema'        => letslapse_rig_schema(),
			'labelDefaults' => letslapse_rig_label_defaults(),
			// The editor draws the same SVG render.php inlines.
			'mark'          => letslapse_rig_mark( 'editor' ),
		)
	);

	letslapse_inline_editor_data(
		'letslapse/brand-mark',
		'letsLapseBrandMark',
		array(
			'sources' => array(
				'dark'  => get_theme_file_uri( 'assets/img/letslapse-icon-dark.svg' ),
				'light' => get_theme_file_uri( 'assets/img/letslapse-icon-light.svg' ),
			),
		)
	);
}
add_action( 'enqueue_block_editor_assets', 'letslapse_block_editor_data' );

/**
 * A media-library image URL, for use inside a pattern.
 *
 * Core saves absolute URLs into block markup, so a URL typed into a pattern
 * would still point at the machine the pattern was written on. Resolving from
 * the attachment id at render time keeps the pattern right on any install that
 * shares this media library, and harmlessly empty on one that does not.
 *
 * @param int    $id   Attachment id.
 * @param string $size Registered image size.
 * @return string URL, or '' when there is no such attachment.
 */
function letslapse_pattern_image_url( $id, $size = 'full' ) {
	$url = wp_get_attachment_image_url( (int) $id, $size );

	return $url ? $url : '';
}

/**
 * Pattern category for anything this theme ships.
 */
function letslapse_register_pattern_category() {
	if ( ! function_exists( 'register_block_pattern_category' ) ) {
		return;
	}

	register_block_pattern_category(
		'letslapse',
		array( 'label' => __( 'LetsLapse', 'letslapse' ) )
	);
}
add_action( 'init', 'letslapse_register_pattern_category', 9 );

/**
 * Block style variations for the copy the machine block used to own.
 *
 * Registering them as styles (rather than baking classes into a pattern) means
 * they show up in the editor's Styles panel, so the copy stays formattable
 * without anyone hand-editing class names.
 */
function letslapse_register_block_styles() {
	register_block_style(
		'core/heading',
		array(
			'name'  => 'll-display',
			'label' => __( 'Display', 'letslapse' ),
		)
	);

	register_block_style(
		'core/paragraph',
		array(
			'name'  => 'll-standfirst',
			'label' => __( 'Standfirst', 'letslapse' ),
		)
	);

	register_block_style(
		'core/paragraph',
		array(
			'name'  => 'll-caption',
			'label' => __( 'Caption', 'letslapse' ),
		)
	);

	register_block_style(
		'core/paragraph',
		array(
			'name'  => 'll-chip',
			'label' => __( 'Chip', 'letslapse' ),
		)
	);

	// Photography. A shot is a framed picture in a column; a band runs edge to
	// edge and is there to give the page somewhere to breathe.
	register_block_style(
		'core/image',
		array(
			'name'  => 'll-shot',
			'label' => __( 'Field shot', 'letslapse' ),
		)
	);

	foreach ( array( 'core/image', 'core/cover' ) as $block ) {
		register_block_style(
			$block,
			array(
				'name'  => 'll-band',
				'label' => __( 'Band', 'letslapse' ),
			)
		);
	}
}
add_action( 'init', 'letslapse_register_block_styles' );
