package com.mendix.metrics;

/** A metric of the application. */
public interface Metric {
	/** Describes and tags a metric before it is built. */
	interface Builder<M extends Metric> {
		Builder<M> withDescription(String description);
		Builder<M> withTag(String name, String value);

		default Builder<M> withTags(java.util.Map<String, String> tags) {
			tags.forEach(this::withTag);
			return this;
		}

		M build();
	}
}
