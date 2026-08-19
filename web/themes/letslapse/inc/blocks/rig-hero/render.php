<?php
/**
 * Server render for letslapse/rig-hero.
 *
 * The block is the mark and the stage it stands on; the words beside it are
 * ordinary blocks nested inside, so copy stays where an editor expects to find
 * it. All the block adds is the timing — it holds the copy back until the rig
 * has finished building itself.
 *
 * No JavaScript is required for any of that: the animation is CSS, and it runs
 * on load. The view script only adds the two things CSS cannot do — holding a
 * rig that is still below the fold, and replaying one on demand.
 *
 * @var array    $attributes Block attributes.
 * @var string   $content    Rendered inner blocks.
 * @var WP_Block $block      Block instance.
 *
 * @package LetsLapse
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

$ll_config = letslapse_rig_config( $attributes );
$ll_labels = letslapse_rig_labels( $attributes, $ll_config );
$ll_uid    = letslapse_rig_next_uid();

$ll_classes = array(
	'll-rig-hero',
	'll-rig-hero--' . $ll_config['arrangement'],
);

if ( $ll_config['showStage'] ) {
	$ll_classes[] = 'has-stage';
}

$ll_photo = letslapse_rig_photo( $ll_config );

if ( '' !== $ll_photo ) {
	$ll_classes[] = 'has-photo';
}

$ll_style = sprintf(
	'--ll-rig-sp:%s;--ll-rig-size:%dpx;--ll-rig-copy-delay:%ss;--ll-rig-scrim:%s',
	$ll_config['sp'],
	$ll_config['markSize'],
	$ll_config['copyDelay'],
	$ll_config['scrim']
);

$ll_wrapper = get_block_wrapper_attributes(
	array(
		'class' => implode( ' ', $ll_classes ),
		'style' => $ll_style,
	)
);

$ll_wordmark = $ll_config['showWordmark'] ? trim( (string) $ll_labels['wordmark'] ) : '';
$ll_replay   = $ll_config['showReplay'] ? trim( (string) $ll_labels['replay'] ) : '';
$ll_mark_alt = trim( (string) $ll_labels['mark'] );
?>
<div <?php echo $ll_wrapper; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?> data-ll-rig-hero>
	<?php if ( '' !== $ll_photo ) : ?>
		<?php echo $ll_photo; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?>
		<?php /* Holds the copy's contrast, and keeps the stage's own glow over the photo. */ ?>
		<div class="ll-rig-hero__scrim" aria-hidden="true"></div>
	<?php endif; ?>

	<div class="ll-rig-hero__mark">
		<?php
		/*
		 * An emptied label means the mark is decorative — which it is whenever
		 * the copy beside it already says the same thing.
		 */
		?>
		<div class="ll-rig ll-rig--<?php echo esc_attr( $ll_config['variant'] ); ?>"
			<?php if ( '' !== $ll_mark_alt ) : ?>
				role="img" aria-label="<?php echo esc_attr( $ll_mark_alt ); ?>"
			<?php else : ?>
				aria-hidden="true"
			<?php endif; ?>
			data-ll-rig>
			<?php echo letslapse_rig_mark( $ll_uid ); // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?>
		</div>

		<?php if ( '' !== $ll_wordmark ) : ?>
			<p class="ll-rig-hero__wordmark"><?php echo esc_html( $ll_wordmark ); ?></p>
		<?php endif; ?>

		<?php /* Hidden until the view script can actually make it replay. */ ?>
		<?php if ( '' !== $ll_replay ) : ?>
			<button type="button" class="ll-rig-hero__replay" data-ll-rig-replay hidden>
				<span aria-hidden="true">↻</span>&nbsp;<?php echo esc_html( $ll_replay ); ?>
			</button>
		<?php endif; ?>
	</div>

	<?php if ( '' !== trim( (string) $content ) ) : ?>
		<div class="ll-rig-hero__copy"><?php echo $content; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?></div>
	<?php endif; ?>
</div>
