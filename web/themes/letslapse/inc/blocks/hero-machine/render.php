<?php
/**
 * Server render for letslapse/hero-machine.
 *
 * The block is the machine and nothing else — headings, standfirsts and any
 * surrounding prose are ordinary blocks on the page, so copy stays where an
 * editor expects to find it. Everything the canvas draws in words comes from
 * the attributes below.
 *
 * Two modes share one canvas. `stack` is the blend machine; `compare` puts a
 * traditional timelapse and a LetsLapse blend of the same footage side by side
 * and can reveal the machine as a sub-view. Compare mode's controls are real
 * DOM — canvas-drawn buttons would lose focus, keyboard and screen readers,
 * which is not a trade worth making on a marketing page.
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
$ll_compare       = 'compare' === $ll_config['mode'];
$ll_wipe          = $ll_compare && 'wipe' === $ll_config['compareStage'];

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
	'loops'        => $ll_config['compareLoops'],
	'mode'         => $ll_config['mode'],
	'stage'        => $ll_config['compareStage'],
	'showTimeline' => (bool) $ll_show_timeline,
	'showCount'    => (bool) $ll_show_count,
	'labels'       => $ll_labels,
);

if ( $ll_compare ) {
	$ll_alt = sprintf(
		/* translators: 1: blend ratio, 2: number of blended frames. */
		__( 'A comparison: the same footage as a traditional timelapse, which keeps one frame in %1$d, and as a LetsLapse blend, which averages all %1$d into each of %2$d finished frames.', 'letslapse' ),
		$ll_config['blendRatio'],
		$ll_config['outputCount']
	);
} else {
	$ll_alt = sprintf(
		/* translators: 1: blend ratio, 2: number of blended frames. */
		__( 'A working diagram: source frames feed in from the left, %1$d of them average together into one blended frame, and the %2$d finished blends play back as a timelapse.', 'letslapse' ),
		$ll_config['blendRatio'],
		$ll_config['outputCount']
	);
}

$ll_wrapper = get_block_wrapper_attributes(
	array( 'class' => 'll-machine' . ( $ll_compare ? ' is-compare' : '' ) )
);
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
		<?php if ( $ll_compare ) : ?>
			<?php
			/*
			 * Two views and one action. They are not three peers: the first pair
			 * are two ways of seeing the same footage, the third is a verb, so
			 * it is set apart. The pair are toggle buttons rather than radios —
			 * in wipe mode the divider can sit between them, and a radiogroup
			 * with nothing chosen (plus a roving tabindex to maintain) buys
			 * nothing a pressed pair does not. The view script positions the row
			 * into the band the canvas reserves, and measures it back to settle
			 * the layout.
			 */
			?>
			<div class="ll-machine__controls" data-ll-controls>
				<div class="ll-machine__seg" role="group" aria-label="<?php esc_attr_e( 'Comparison', 'letslapse' ); ?>">
					<button type="button" class="ll-machine__view" data-ll-view="traditional" aria-pressed="true">
						<?php echo esc_html( $ll_labels['traditional'] ); ?>
					</button>
					<button type="button" class="ll-machine__view" data-ll-view="letslapse" aria-pressed="false">
						<?php echo esc_html( $ll_labels['letslapse'] ); ?>
					</button>
					<?php if ( '' !== trim( (string) $ll_labels['auto'] ) ) : ?>
						<span class="ll-machine__auto" data-ll-auto aria-hidden="true"><?php echo esc_html( $ll_labels['auto'] ); ?></span>
					<?php endif; ?>
				</div>
				<?php if ( '' !== trim( (string) $ll_labels['workflow'] ) ) : ?>
					<button type="button" class="ll-machine__action" data-ll-view="workflow">
						<?php echo esc_html( $ll_labels['workflow'] ); ?>
					</button>
				<?php endif; ?>
			</div>
			<?php if ( $ll_wipe ) : ?>
				<?php
				/*
				 * The divider is DOM, not canvas: it needs a grab cursor, a focus
				 * ring and arrow keys. The canvas only draws the split it sits on.
				 */
				?>
				<div
					class="ll-machine__wipe"
					data-ll-wipe
					role="slider"
					tabindex="0"
					aria-label="<?php esc_attr_e( 'Comparison split', 'letslapse' ); ?>"
					aria-valuemin="0"
					aria-valuemax="100"
					aria-valuenow="100"
					aria-valuetext="<?php echo esc_attr( $ll_labels['traditional'] ); ?>"
				><span class="ll-machine__wipe-grip" aria-hidden="true"></span></div>
			<?php endif; ?>
		<?php elseif ( '' !== trim( (string) $ll_labels['replay'] ) ) : ?>
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
