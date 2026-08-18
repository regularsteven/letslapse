<?php
/**
 * Server render for letslapse/hero-machine.
 *
 * The block is the machine and nothing else — headings, standfirsts and any
 * surrounding prose are ordinary blocks on the page, so copy stays where an
 * editor expects to find it. Everything the canvas draws in words comes from
 * the attributes below.
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
$ll_labels = letslapse_hero_labels( $attributes, $ll_config );

$ll_show_timeline = ! isset( $attributes['showTimeline'] ) || $attributes['showTimeline'];
$ll_show_count    = ! isset( $attributes['showPlayingCount'] ) || $attributes['showPlayingCount'];

// Everything the canvas needs, in one JSON payload.
$ll_payload = array(
	'atlas'        => $ll_config['atlasUrl'],
	'cols'         => $ll_config['atlasCols'],
	'frames'       => $ll_config['frameCount'],
	'frameSize'    => $ll_config['atlasFrameSize'],
	'srcFps'       => $ll_config['sourceFps'],
	'ratio'        => $ll_config['blendRatio'],
	'outputs'      => $ll_config['outputCount'],
	'startRate'    => $ll_config['startRate'],
	'accel'        => $ll_config['accel'],
	'maxRate'      => $ll_config['maxRate'],
	'playFps'      => $ll_config['playFps'],
	'showTimeline' => (bool) $ll_show_timeline,
	'showCount'    => (bool) $ll_show_count,
	'labels'       => $ll_labels,
);

$ll_alt = sprintf(
	/* translators: 1: blend ratio, 2: number of blended frames. */
	__( 'A working diagram: source frames feed in from the left, %1$d of them average together into one blended frame, and the %2$d finished blends play back as a timelapse.', 'letslapse' ),
	$ll_config['blendRatio'],
	$ll_config['outputCount']
);

$ll_wrapper = get_block_wrapper_attributes( array( 'class' => 'll-machine' ) );
?>
<div <?php echo $ll_wrapper; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?>>
	<div class="ll-machine__stage" data-ll-machine data-ll-config="<?php echo esc_attr( wp_json_encode( $ll_payload ) ); ?>">
		<?php
		/*
		 * The atlas is the heaviest thing the machine pulls, so hint it early. It
		 * lives in here rather than beside the block: as a sibling it would count
		 * as a layout child, pushing the block off :first-child and earning it a
		 * stray block gap. rel=preload is body-ok, and the preload scanner only
		 * cares where it lands in the byte stream.
		 */
		letslapse_hero_preload_atlas( $ll_config['atlasUrl'] );
		?>
		<canvas class="ll-machine__canvas" role="img" aria-label="<?php echo esc_attr( $ll_alt ); ?>"></canvas>
		<?php if ( '' !== trim( (string) $ll_labels['replay'] ) ) : ?>
			<button type="button" class="ll-machine__replay" data-ll-replay hidden>
				<span aria-hidden="true">↻</span>&nbsp;<?php echo esc_html( $ll_labels['replay'] ); ?>
			</button>
		<?php endif; ?>
		<noscript>
			<p class="ll-machine__noscript"><?php echo esc_html( $ll_alt ); ?></p>
		</noscript>
	</div>

	<?php /* Revealed by the view script only if the atlas fails to load. */ ?>
	<p class="ll-machine__fallback" data-ll-fallback hidden><?php echo esc_html( $ll_alt ); ?></p>
</div>
