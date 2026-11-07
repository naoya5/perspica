import Foundation

/// The text the panel demos use (SPEC 15). It is three paragraphs and the
/// first one is over the chunking limit, so `--demo-state done` also shows that
/// a long source is split and put back together with the paragraphs intact.
enum DemoText {
    static let threeParagraphs = """
        The dominant sequence transduction models are based on complex recurrent or convolutional neural networks that include an encoder and a decoder. The best performing models also connect the encoder and decoder through an attention mechanism. We propose a new simple network architecture, the Transformer, based solely on attention mechanisms, dispensing with recurrence and convolutions entirely. Experiments on two machine translation tasks show these models to be superior in quality while being more parallelizable and requiring significantly less time to train. Our model achieves 28.4 BLEU on the WMT 2014 English-to-German translation task, improving over the existing best results, including ensembles, by over 2 BLEU. On the WMT 2014 English-to-French translation task, our model establishes a new single-model state-of-the-art BLEU score of 41.8 after training for 3.5 days on eight GPUs, a small fraction of the training costs of the best models from the literature. Recurrent models typically factor computation along the symbol positions of the input and output sequences, which precludes parallelization within training examples and becomes a critical bottleneck at longer sequence lengths.

        Attention mechanisms have become an integral part of compelling sequence modeling and transduction models in various tasks, allowing modeling of dependencies without regard to their distance in the input or output sequences. In all but a few cases, however, such attention mechanisms are used in conjunction with a recurrent network.

        To the best of our knowledge, however, the Transformer is the first transduction model relying entirely on self-attention to compute representations of its input and output without using sequence-aligned RNNs or convolution. In the following sections, we will describe the Transformer, motivate self-attention and discuss its advantages over models such as the recurrent and convolutional approaches.
        """

    static let selectionSample = "The best performing models also connect the encoder and decoder through an attention mechanism."
}
