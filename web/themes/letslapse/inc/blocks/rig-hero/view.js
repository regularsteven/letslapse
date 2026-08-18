/**
 * Rig hero — front-end script.
 *
 * The animation itself is pure CSS and runs on load, so this file is optional
 * by design: with JavaScript off, a visitor still sees the rig build and the
 * copy arrive. All that is added here are the two things a stylesheet cannot
 * decide on its own:
 *
 *   1. A rig further down the page shouldn't have built itself before anyone
 *      scrolled to it. Those are paused at frame zero and released on sight.
 *   2. Replay, for anyone who wants to watch it again.
 *
 * Both go through the Web Animations API, which is also the honest gate for
 * the replay control: no getAnimations(), no button.
 */
( function () {
	'use strict';

	var SELECTOR = '[data-ll-rig-hero]';
	var VISIBLE_FRACTION = 0.25;

	function canDrive() {
		return typeof document.getAnimations === 'function';
	}

	function prefersReducedMotion() {
		return !! ( window.matchMedia && window.matchMedia( '(prefers-reduced-motion: reduce)' ).matches );
	}

	/**
	 * The one-shot animations inside a hero.
	 *
	 * The loop variant's idle motion — sweep, bob, pulse — is deliberately left
	 * alone: it has no start to wait for and no end to replay.
	 *
	 * @param {Element} root Hero element.
	 * @return {Animation[]} Finite animations under that root.
	 */
	function animationsIn( root ) {
		return document.getAnimations().filter( function ( animation ) {
			var target = animation.effect && animation.effect.target;

			if ( ! target || ! root.contains( target ) ) {
				return false;
			}

			return animation.effect.getTiming().iterations !== Infinity;
		} );
	}

	/** Freeze at frame zero: fill-mode backwards leaves every part unbuilt. */
	function hold( root ) {
		animationsIn( root ).forEach( function ( animation ) {
			animation.pause();
			animation.currentTime = 0;
		} );
	}

	function play( root ) {
		animationsIn( root ).forEach( function ( animation ) {
			animation.cancel();
			animation.play();
		} );
	}

	/**
	 * Hold a hero that is off screen, and release it when it arrives.
	 *
	 * @param {Element} root Hero element.
	 */
	function armOnSight( root ) {
		if ( ! window.IntersectionObserver ) {
			return;
		}

		var observer = new IntersectionObserver(
			function ( entries ) {
				entries.forEach( function ( entry ) {
					if ( ! entry.isIntersecting ) {
						return;
					}

					observer.disconnect();
					play( root );
				} );
			},
			{ threshold: VISIBLE_FRACTION }
		);

		/*
		 * One frame of observation tells us whether this rig is already on
		 * screen. If it is, it keeps the head start the page load gave it.
		 */
		var settle = new IntersectionObserver(
			function ( entries ) {
				settle.disconnect();

				if ( entries.length && entries[ 0 ].isIntersecting ) {
					return;
				}

				hold( root );
				observer.observe( root );
			},
			{ threshold: VISIBLE_FRACTION }
		);

		settle.observe( root );
	}

	function setUp( root ) {
		var replay = root.querySelector( '[data-ll-rig-replay]' );

		if ( replay ) {
			replay.hidden = false;
			replay.addEventListener( 'click', function () {
				play( root );
			} );
		}

		armOnSight( root );
	}

	function init() {
		if ( ! canDrive() || prefersReducedMotion() ) {
			return;
		}

		Array.prototype.forEach.call( document.querySelectorAll( SELECTOR ), setUp );
	}

	if ( document.readyState === 'loading' ) {
		document.addEventListener( 'DOMContentLoaded', init );
	} else {
		init();
	}
}() );
