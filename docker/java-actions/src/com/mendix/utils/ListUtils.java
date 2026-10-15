package com.mendix.utils;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;

/** List helpers of the Runtime API. */
public final class ListUtils {
	private ListUtils() {
	}

	public static <A, B> List<B> map(List<A> list, Function<A, B> function) {
		List<B> result = new ArrayList<>(list.size());
		for (A item : list) {
			result.add(function.apply(item));
		}
		return result;
	}

	public static <A, B> List<B> flatMap(List<A> list, Function<A, List<B>> function) {
		List<B> result = new ArrayList<>();
		for (A item : list) {
			result.addAll(function.apply(item));
		}
		return result;
	}
}
