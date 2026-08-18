<?php
/**
 * Server render for letslapse/hero-machine.
 *
 * @var array    $attributes Block attributes.
 * @var string   $content    Inner content (unused).
 * @var WP_Block $block      Block instance.
 *
 * @package LetsLapse
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

$ll_config = letslapse_hero_config( $attributes );

$ll_level   = isset( $attributes['headingLevel'] ) ? (int) $attributes['headingLevel'] : 1;
$ll_level   = max( 1, min( 6, $ll_level ) );
$ll_tag     = 'h' . $ll_level;

$ll_heading    = isset( $attributes['heading'] ) ? $attributes['heading'] : '';
$ll_subheading = isset( $attributes['subheading'] ) ? $attributes['subheading'] : '';
$ll_note       = isset( $attributes['note'] ) ? $attributes['note'] : '';
$ll_replay     = isset( $attributes['replayLabel'] ) && '' !== $attributes['replayLabel']
	? $attributes['replayLabel']
	: __( 'Replay the machine', 'letslapse' );

$ll_show_caption = ! isset( $attributes['showCaption'] ) || $attributes['showCaption'];
$ll_show_note    = ( ! isset( $attributes['showNote'] ) || $attributes['showNote'] ) && '' !== trim( (string) $ll_note );

$ll_caption = isset( $attributes['caption'] ) && '' !== trim( (string) $attributes['caption'] )
	? $attributes['caption']
	: letslapse_hero_default_caption( $ll_config );

// Everything the canvas needs, in one JSON payload. Labels come through here
// too, so nothing user-facing is hardcoded inside the script.
$ll_payload = array(
	'atlas'     => $ll_config['atlasUrl'],
	'cols'      => $ll_config['atlasCols'],
	'frames'    => $ll_config['frameCount'],
	'frameSize' => $ll_config['atlasFrameSize'],
	'srcFps'    => $ll_config['sourceFps'],
	'ratio'     => $ll_config['blendRatio'],
	'outputs'   => $ll_config['outputCount'],
	'startRate' => $ll_config['startRate'],
	'accel'     => $ll_config['accel'],
	'maxRate'   => $ll_config['maxRate'],
	'playFps'   => $ll_config['playFps'],
	'labels'    => array(
		'source'   => sprintf(
			/* translators: %s: source frame rate. */
			__( '← SOURCE · %s FPS', 'letslapse' ),
			number_format_i18n( $ll_config['sourceFps'] )
		),
		'output'   => __( 'READY FOR OUTPUT →', 'letslapse' ),
		'timeline' => sprintf(
			/* translators: %s: seconds of source footage represented by one blended frame. */
			__( 'TIMELINE · 1 BLEND = %s S OF SOURCE', 'letslapse' ),
			$ll_config['blendSeconds']
		),
		'stacking' => sprintf(
			/* translators: 1: frames stacked so far, 2: blend ratio, 3: current blend index, 4: total blends. Tokens are substituted client-side. */
			__( '%1$s / %2$s · blend %3$s of %4$s', 'letslapse' ),
			'{stacked}',
			'{ratio}',
			'{blend}',
			'{outputs}'
		),
		'playing'  => sprintf(
			/* translators: 1: current blend index, 2: total blends. Tokens are substituted client-side. */
			__( 'playing · blend %1$s / %2$s', 'letslapse' ),
			'{index}',
			'{total}'
		),
		'resetting' => __( 'loop restarting…', 'letslapse' ),
		'reduced'   => __( 'Reduced motion — showing the finished stack', 'letslapse' ),
	),
);

$ll_alt = sprintf(
	/* translators: 1: blend ratio, 2: number of blended frames. */
	__( 'A working diagram: source frames feed in from the left, %1$d of them average together into one blended frame, and the %2$d finished blends play back as a timelapse.', 'letslapse' ),
	$ll_config['blendRatio'],
	$ll_config['outputCount']
);

$ll_wrapper = get_block_wrapper_attributes( array( 'class' => 'll-hero' ) );

?>
<section <?php echo $ll_wrapper; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?>>
	<?php if ( '' !== trim( (string) $ll_heading ) ) : ?>
		<<?php echo esc_attr( $ll_tag ); ?> class="ll-hero__heading"><?php echo wp_kses_post( $ll_heading ); ?></<?php echo esc_attr( $ll_tag ); ?>>
	<?php endif; ?>

	<?php if ( '' !== trim( (string) $ll_subheading ) ) : ?>
		<p class="ll-hero__standfirst"><?php echo wp_kses_post( $ll_subheading ); ?></p>
	<?php endif; ?>

	<div class="ll-hero__machine" data-ll-machine data-ll-config="<?php echo esc_attr( wp_json_encode( $ll_payload ) ); ?>">
		<?php
		/*
		 * The atlas is the heaviest thing the hero pulls, so hint it early. It
		 * lives in here rather than beside the section: as a sibling it would
		 * count as a layout child, pushing the hero off :first-child and
		 * earning it a stray block gap. rel=preload is body-ok, and the
		 * preload scanner only cares where it lands in the byte stream.
		 */
		letslapse_hero_preload_atlas( $ll_config['atlasUrl'] );
		?>
		<canvas class="ll-hero__canvas" role="img" aria-label="<?php echo esc_attr( $ll_alt ); ?>"></canvas>
		<button type="button" class="ll-hero__replay" data-ll-replay hidden>
			<span aria-hidden="true">↻</span>&nbsp;<?php echo esc_html( $ll_replay ); ?>
		</button>
		<noscript>
			<p class="ll-hero__noscript"><?php echo esc_html( $ll_alt ); ?></p>
		</noscript>
	</div>

	<?php /* Revealed by the view script only if the atlas fails to load. */ ?>
	<p class="ll-hero__fallback" data-ll-fallback hidden><?php echo esc_html( $ll_alt ); ?></p>

	<?php if ( $ll_show_caption || $ll_show_note ) : ?>
		<div class="ll-hero__meta">
			<?php if ( $ll_show_caption ) : ?>
				<p class="ll-hero__caption"><?php echo wp_kses_post( $ll_caption ); ?></p>
			<?php endif; ?>
			<?php if ( $ll_show_note ) : ?>
				<span class="ll-hero__chip"><?php echo wp_kses_post( $ll_note ); ?></span>
			<?php endif; ?>
		</div>
	<?php endif; ?>
</section>
