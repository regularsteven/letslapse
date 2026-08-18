<?php
/**
 * Rig hero — configuration and the mark itself.
 *
 * The block renders on the server and previews in the editor, and both need the
 * same clamped numbers and the same SVG. They come from here, so the editor
 * cannot drift from the front end.
 *
 * @package LetsLapse
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Bounds for every number the rig animates on.
 *
 * Speed mirrors the design's own Motion tweak (0.4–1.4, 1 = as authored).
 *
 * @return array<string, array{default: float|int, min: float|int, max: float|int, int: bool}>
 */
function letslapse_rig_schema() {
	$schema = array(
		'markSize' => array( 'default' => 216, 'min' => 64,  'max' => 480, 'int' => true ),
		'speed'    => array( 'default' => 1,   'min' => 0.4, 'max' => 1.4, 'int' => false ),
	);

	/**
	 * Filters the rig hero parameter schema (defaults and bounds).
	 *
	 * @param array $schema Parameter schema.
	 */
	return apply_filters( 'letslapse_rig_schema', $schema );
}

/**
 * Default copy. Every string the block draws is an attribute, so all of it is
 * editable per instance; an empty string hides that element.
 *
 * @return array<string, string>
 */
function letslapse_rig_label_defaults() {
	return array(
		'wordmark'  => __( 'LETSLAPSE', 'letslapse' ),
		'replay'    => __( 'Replay', 'letslapse' ),
		'markBuild' => __( 'The LetsLapse rig assembling itself: legs, body, board and lens.', 'letslapse' ),
		'markLoop'  => __( 'The LetsLapse rig running, with a light sweeping its body.', 'letslapse' ),
	);
}

/**
 * Clamp and complete raw attributes into a render-ready config.
 *
 * @param array $attributes Raw block attributes.
 * @return array
 */
function letslapse_rig_config( $attributes = array() ) {
	$schema = letslapse_rig_schema();
	$config = array();

	foreach ( $schema as $key => $rule ) {
		$value = isset( $attributes[ $key ] ) && '' !== $attributes[ $key ]
			? (float) $attributes[ $key ]
			: (float) $rule['default'];

		$value = max( (float) $rule['min'], min( (float) $rule['max'], $value ) );

		$config[ $key ] = $rule['int'] ? (int) round( $value ) : (float) $value;
	}

	$config['variant'] = ( isset( $attributes['variant'] ) && 'loop' === $attributes['variant'] ) ? 'loop' : 'build';
	$config['arrangement'] = ( isset( $attributes['arrangement'] ) && 'inline' === $attributes['arrangement'] ) ? 'inline' : 'stack';

	$config['showStage']    = ! isset( $attributes['showStage'] ) || $attributes['showStage'];
	$config['showWordmark'] = ! isset( $attributes['showWordmark'] ) || $attributes['showWordmark'];
	$config['showReplay']   = isset( $attributes['showReplay'] ) && $attributes['showReplay'];

	// Seconds multiplier: the design's --sp, which is 1 / speed.
	$config['sp'] = round( 1 / $config['speed'], 3 );

	/*
	 * When the copy arrives. The build hands over at 1.78 s — after the glint,
	 * as the glow settles to idle. The loop has no such moment, so its copy is
	 * only just behind the mark.
	 */
	$config['copyDelay'] = 'loop' === $config['variant']
		? round( 0.3 * $config['sp'], 3 )
		: round( 1.78 * $config['sp'], 3 );

	/**
	 * Filters the resolved rig hero config.
	 *
	 * @param array $config     Normalised config.
	 * @param array $attributes Raw attributes it was built from.
	 */
	return apply_filters( 'letslapse_rig_config', $config, $attributes );
}

/**
 * Resolve the block's copy against the defaults.
 *
 * @param array $attributes Raw block attributes.
 * @param array $config     Resolved config.
 * @return array<string, string>
 */
function letslapse_rig_labels( $attributes, $config ) {
	$defaults = letslapse_rig_label_defaults();

	$labels = array(
		'wordmark' => isset( $attributes['wordmarkText'] ) ? (string) $attributes['wordmarkText'] : $defaults['wordmark'],
		'replay'   => isset( $attributes['replayLabel'] ) ? (string) $attributes['replayLabel'] : $defaults['replay'],
	);

	$fallback = 'loop' === $config['variant'] ? $defaults['markLoop'] : $defaults['markBuild'];

	$labels['mark'] = isset( $attributes['markLabel'] ) ? (string) $attributes['markLabel'] : $fallback;

	/**
	 * Filters the resolved rig hero copy.
	 *
	 * @param array $labels     Resolved labels.
	 * @param array $attributes Raw attributes.
	 * @param array $config     Resolved config.
	 */
	return apply_filters( 'letslapse_rig_labels', $labels, $attributes, $config );
}

/**
 * The rig mark, with its gradient ids namespaced to one instance.
 *
 * Inline rather than an <img>: the animation is CSS, the accent is a theme
 * custom property, and both have to reach inside the SVG.
 *
 * @param string $uid Suffix appended to every gradient id.
 * @return string SVG markup.
 */
function letslapse_rig_mark( $uid = '' ) {
	static $source = null;

	if ( null === $source ) {
		$path   = get_theme_file_path( 'inc/blocks/rig-hero/mark.svg' );
		$source = file_exists( $path ) ? (string) file_get_contents( $path ) : ''; // phpcs:ignore WordPress.WP.AlternativeFunctions.file_get_contents_file_get_contents

		// The file leads with a note to whoever opens it; visitors don't need it.
		$start = strpos( $source, '<svg' );

		$source = ( false === $start ) ? '' : substr( $source, $start );
	}

	if ( '' === $source ) {
		return '';
	}

	return str_replace( '{{uid}}', $uid ? '-' . preg_replace( '/[^A-Za-z0-9_-]/', '', (string) $uid ) : '', $source );
}

/**
 * A per-page instance counter, so two rigs never share a gradient id.
 *
 * @return int
 */
function letslapse_rig_next_uid() {
	static $n = 0;

	return ++$n;
}
