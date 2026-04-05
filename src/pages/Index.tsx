const Index = () => {
  return (
    <div className="fixed inset-0 w-screen h-screen flex flex-col">
      <div
        className="w-full bg-white flex-shrink-0"
        style={{ height: 'env(safe-area-inset-top, 0px)' }}
      />
      <iframe
        src="https://birdz.sk"
        className="w-full flex-1 border-0"
        allow="notifications; camera; microphone; geolocation"
        title="Birdz.sk"
      />
    </div>
  );
};

export default Index;
