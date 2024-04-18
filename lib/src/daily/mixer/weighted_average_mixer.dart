import 'dart:math';

import 'package:yahoo_finance_data_reader/src/daily/mixer/average_mixer.dart';
import 'package:yahoo_finance_data_reader/yahoo_finance_data_reader.dart';

class WeightedAverageMixer {
  /// Mix a map of weights to lists of prices dataframes according to the defined weights
  static List<YahooFinanceCandleData> mix(Map<List<YahooFinanceCandleData>, double> weightedPricesList) {
    if (weightedPricesList.isEmpty) {
      return [];
    }

    // Ensure all lists are of the same size and start from the same date
    AverageMixer.preparePricesList(weightedPricesList.keys.toList());

    // Calculate proportions for each asset based on the maximum open value
    final proportions = calculateProportions(weightedPricesList.keys.toList());

    // Calculate the total weight for normalization
    final double totalWeight = weightedPricesList.values.fold(0, (sum, item) => sum + item);

    // Merge the prices using weights and proportions
    return mergeWeightedPrices(weightedPricesList, totalWeight, proportions);
  }

  static List<double> calculateProportions(List<List<YahooFinanceCandleData>> pricesList) {
    final maxOpenValue = pricesList.expand((list) => list).map((candle) => candle.open).reduce(max);

    return pricesList.map((list) => list.first.open / maxOpenValue).toList();
  }

  static List<YahooFinanceCandleData> mergeWeightedPrices(
      Map<List<YahooFinanceCandleData>, double> weightedPricesList, double totalWeight, List<double> proportions) {
    final int numberOfTimePoints = weightedPricesList.keys.first.length;
    final List<YahooFinanceCandleData> result = [];
    int assetIndex = 0;

    for (int d = 0; d < numberOfTimePoints; d++) {
      final DateTime currentDate = weightedPricesList.keys.first[d].date;
      double sumOpen = 0;
      double sumClose = 0;
      double sumCloseAdj = 0;
      double sumHigh = 0;
      double sumLow = 0;
      double sumVolume = 0;

      weightedPricesList.forEach((prices, weight) {
        final int currentAssetIndex = d < prices.length ? d : prices.length - 1;
        final YahooFinanceCandleData candle = prices[currentAssetIndex];

        // Adjust the sums using the weight of each asset and the proportion
        final double adjustedWeight = weight / totalWeight;
        final double proportion = proportions[assetIndex];
        sumOpen += (candle.open / proportion) * adjustedWeight;
        sumClose += (candle.close / proportion) * adjustedWeight;
        sumCloseAdj += (candle.adjClose / proportion) * adjustedWeight;
        sumLow += (candle.low / proportion) * adjustedWeight;
        sumHigh += (candle.high / proportion) * adjustedWeight;
        sumVolume += (candle.volume / proportion) * adjustedWeight;
      });

      result.add(YahooFinanceCandleData(
          open: sumOpen,
          close: sumClose,
          adjClose: sumCloseAdj,
          high: sumHigh,
          low: sumLow,
          volume: sumVolume.round(),
          date: currentDate));

      assetIndex = (assetIndex + 1) % weightedPricesList.length;
    }

    return result;
  }
}
