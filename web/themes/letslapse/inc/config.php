<?php
/**
 * Single source of truth for the blend-machine numbers.
 *
 * Every number the hero animates on — and every number the surrounding copy
 * quotes — comes through here, so the prose can never drift from the maths.
 *
 * @package LetsLapse
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Default machine configuration.
 *
 * Mirrors the prop defaults and bounds of the source design
 * (LetsLapse Homepage.dc.html, `Component.cfg()`).
 *
 * @return array<string, array{default: float|int, min: float|int, max: float|int, int: bool}>
 */
function letslapse_hero_schema() {
	$schema = array(
		'blendRatio'     => array( 'default' => 15,  'min' => 2,   'max' => 30,  'int' => true ),
		'outputCount'    => array( 'default' => 8,   'min' => 3,   'max' => 12,  'int' => true ),
		'frameCount'     => array( 'default' => 120, 'min' => 1,   'max' => 500, 'int' => true ),
		'atlasCols'      => array( 'default' => 11,  'min' => 1,   'max' => 50,  'int' => true ),
		'atlasFrameSize' => array( 'default' => 320, 'min' => 16,  'max' => 2048, 'int' => true ),
		'sourceFps'      => array( 'default' => 15,  'min' => 1,   'max' => 240, 'int' => true ),
		'startRate'      => array( 'default' => 1.6, 'min' => 0.5, 'max' => 6,   'int' => false ),
		'accel'          => array( 'default' => 1.5, 'min' => 1,   'max' => 2.5, 'int' => false ),
		'maxRate'        => array( 'default' => 16,  'min' => 4,   'max' => 30,  'int' => false ),
		'playFps'        => array( 'default' => 5,   'min' => 1,   'max' => 15,  'int' => false ),
		'compareLoops'   => array( 'default' => 4,   'min' => 1,   'max' => 12,  'int' => true ),
	);

	/**
	 * Filters the blend-machine parameter schema (defaults and bounds).
	 *
	 * @param array $schema Parameter schema.
	 */
	return apply_filters( 'letslapse_hero_schema', $schema );
}

/**
 * The machine's presentation choices, as the editor and the server both see them.
 *
 * `mode` is what the block is showing; `compareStage` is only how compare mode
 * renders its big stage, so the two comparisons share one state machine and
 * differ purely in the transition between them.
 *
 * @return array<string, array<string, string>>
 */
function letslapse_hero_choices() {
	$choices = array(
		'mode'         => array(
			'stack'   => __( 'Stack & blend', 'letslapse' ),
			'compare' => __( 'Traditional vs LetsLapse', 'letslapse' ),
		),
		'compareStage' => array(
			'toggle' => __( 'Toggle (hard cut)', 'letslapse' ),
			'wipe'   => __( 'Wipe (draggable split)', 'letslapse' ),
		),
	);

	/**
	 * Filters the blend-machine presentation choices.
	 *
	 * @param array $choices Choice sets keyed by attribute name.
	 */
	return apply_filters( 'letslapse_hero_choices', $choices );
}

/**
 * Pick a valid value out of one choice set, falling back to its first entry.
 *
 * @param array  $attributes Raw attributes.
 * @param string $key        Attribute name, also the choice-set name.
 * @return string
 */
function letslapse_hero_choice( $attributes, $key ) {
	$choices = letslapse_hero_choices();
	$set     = isset( $choices[ $key ] ) ? $choices[ $key ] : array();
	$keys    = array_keys( $set );
	$value   = isset( $attributes[ $key ] ) ? (string) $attributes[ $key ] : '';

	return in_array( $value, $keys, true ) ? $value : ( isset( $keys[0] ) ? $keys[0] : '' );
}

/**
 * Clamp and complete a raw attribute array into a machine config.
 *
 * @param array $attributes Raw block attributes or shortcode atts.
 * @return array Normalised config plus derived display values.
 */
function letslapse_hero_config( $attributes = array() ) {
	$schema = letslapse_hero_schema();
	$config = array();

	foreach ( $schema as $key => $rule ) {
		$value = isset( $attributes[ $key ] ) && '' !== $attributes[ $key ]
			? (float) $attributes[ $key ]
			: (float) $rule['default'];

		$value = max( (float) $rule['min'], min( (float) $rule['max'], $value ) );

		$config[ $key ] = $rule['int'] ? (int) round( $value ) : (float) $value;
	}

	// Derived values used by both the canvas and the surrounding copy.
	$config['lastOpacity'] = number_format( 100 / $config['blendRatio'], 1 );
	$config['blendSeconds'] = number_format(
		$config['blendRatio'] / $config['sourceFps'],
		( $config['blendRatio'] % $config['sourceFps'] ) ? 1 : 0
	);

	$rates = array();
	for ( $n = 0; $n < $config['outputCount']; $n++ ) {
		$rates[] = number_format(
			min( $config['maxRate'], $config['startRate'] * pow( $config['accel'], $n ) ),
			1
		);
	}
	$config['rateSequence'] = implode( ' · ', $rates );

	$config['mode']         = letslapse_hero_choice( $attributes, 'mode' );
	$config['compareStage'] = letslapse_hero_choice( $attributes, 'compareStage' );

	$config['atlasUrl'] = letslapse_hero_atlas_url( $attributes );

	/**
	 * Filters the resolved blend-machine config.
	 *
	 * @param array $config     Normalised config.
	 * @param array $attributes Raw attributes it was built from.
	 */
	return apply_filters( 'letslapse_hero_config', $config, $attributes );
}

/**
 * Resolve the sprite-atlas URL for a hero instance.
 *
 * @param array $attributes Raw block attributes or shortcode atts.
 * @return string
 */
function letslapse_hero_atlas_url( $attributes = array() ) {
	$url = '';

	if ( ! empty( $attributes['atlasId'] ) ) {
		$attachment = wp_get_attachment_url( (int) $attributes['atlasId'] );
		if ( $attachment ) {
			$url = $attachment;
		}
	}

	if ( ! $url && ! empty( $attributes['atlasUrl'] ) ) {
		$url = $attributes['atlasUrl'];
	}

	if ( ! $url ) {
		$url = get_theme_file_uri( 'assets/img/tram-atlas-11x11.webp' );
	}

	/**
	 * Filters the blend-machine sprite atlas URL.
	 *
	 * @param string $url        Atlas URL.
	 * @param array  $attributes Raw attributes.
	 */
	return apply_filters( 'letslapse_hero_atlas_url', esc_url_raw( $url ), $attributes );
}

/**
 * Default copy for everything the canvas draws in words.
 *
 * Every string is a block attribute, so all of it is editable per instance.
 * Braced tokens are substituted client-side as the machine runs.
 *
 * @return array<string, string>
 */
function letslapse_hero_label_defaults() {
	return array(
		'source'    => __( 'SOURCE INPUT', 'letslapse' ),
		'output'    => __( 'BLENDED OUTPUT', 'letslapse' ),
		'timeline'  => __( 'TIMELINE · 1 BLEND = {seconds} S OF SOURCE', 'letslapse' ),
		'replay'    => __( 'Replay the machine', 'letslapse' ),
		'stacking'  => __( '{stacked} / {ratio} · blend {blend} of {outputs}', 'letslapse' ),
		'playing'   => __( 'playing · blend', 'letslapse' ),
		'resetting' => __( 'loop restarting…', 'letslapse' ),
		'reduced'   => __( 'Reduced motion — showing the finished stack', 'letslapse' ),

		// Compare mode. The two row labels are deliberately symmetrical: the
		// only difference between the rows is what happens to the other 14
		// frames, and the copy should say so.
		'traditional'    => __( 'Traditional timelapse', 'letslapse' ),
		'letslapse'      => __( 'LetsLapse', 'letslapse' ),
		'workflow'       => __( 'Show LetsLapse workflow', 'letslapse' ),
		'traditionalRow' => __( 'TRADITIONAL · 1 FRAME IN {ratio} KEPT', 'letslapse' ),
		'letslapseRow'   => __( 'LETSLAPSE · ALL {ratio} FRAMES AVERAGED', 'letslapse' ),
		'auto'           => __( 'auto', 'letslapse' ),
		'compareStatus'  => __( 'frame {index} / {total}', 'letslapse' ),
	);
}

/**
 * Map block attributes onto the canvas label set.
 *
 * Tokens that depend only on config ({seconds}) are resolved here; the ones
 * that change frame to frame are left for the view script.
 *
 * @param array $attributes Raw block attributes.
 * @param array $config     Resolved config from letslapse_hero_config().
 * @return array<string, string>
 */
function letslapse_hero_labels( $attributes, $config ) {
	$attribute_names = array(
		'source'    => 'sourceLabel',
		'output'    => 'outputLabel',
		'timeline'  => 'timelineLabel',
		'replay'    => 'replayLabel',
		'stacking'  => 'stackingLabel',
		'playing'   => 'playingLabel',
		'resetting' => 'resettingLabel',
		'reduced'   => 'reducedMotionLabel',

		'traditional'    => 'traditionalLabel',
		'letslapse'      => 'letslapseLabel',
		'workflow'       => 'workflowLabel',
		'traditionalRow' => 'traditionalRowLabel',
		'letslapseRow'   => 'letslapseRowLabel',
		'auto'           => 'autoLabel',
		'compareStatus'  => 'compareStatusLabel',
	);

	$labels = array();

	foreach ( letslapse_hero_label_defaults() as $key => $default ) {
		$name = $attribute_names[ $key ];

		// An empty string is meaningful: it hides that label.
		$labels[ $key ] = isset( $attributes[ $name ] ) ? (string) $attributes[ $name ] : $default;
	}

	$tokens = array(
		'{seconds}' => $config['blendSeconds'],
		'{ratio}'   => number_format_i18n( $config['blendRatio'] ),
		'{srcFps}'  => number_format_i18n( $config['sourceFps'] ),
	);

	foreach ( array( 'timeline', 'traditionalRow', 'letslapseRow' ) as $key ) {
		$labels[ $key ] = strtr( $labels[ $key ], $tokens );
	}

	/**
	 * Filters the resolved canvas labels.
	 *
	 * @param array $labels     Resolved labels.
	 * @param array $attributes Raw attributes.
	 * @param array $config     Resolved config.
	 */
	return apply_filters( 'letslapse_hero_labels', $labels, $attributes, $config );
}

/**
 * Emit a one-time preload hint for a hero atlas.
 *
 * The atlas is by far the heaviest thing the hero pulls; the preload lets the
 * browser start it during body parse rather than when the view script runs.
 *
 * @param string $url Atlas URL.
 */
function letslapse_hero_preload_atlas( $url ) {
	static $done = array();

	if ( '' === $url || isset( $done[ $url ] ) ) {
		return;
	}

	$done[ $url ] = true;

	printf(
		'<link rel="preload" as="image" href="%s" fetchpriority="high">' . "\n",
		esc_url( $url )
	);
}
